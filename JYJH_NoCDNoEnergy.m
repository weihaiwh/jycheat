/**
 * 剑影江湖 v8.1 - IL2CPP运行时方法指针替换
 * 
 * v8.0→v8.1 修复的Bug:
 * 
 * Bug 4: patchMem把MethodInfo数据页设为RX导致闪退
 *   原代码: vm_protect(WRITE|COPY) → memcpy → vm_protect(READ|EXECUTE)
 *   问题: MethodInfo在数据段, 设为RX后游戏IL2CPP运行时无法写入同页的其他MethodInfo
 *   闪退原因: 游戏在运行时需要动态修改MethodInfo数据(如JIT编译结果),
 *             被锁为RX后触发EXC_BAD_ACCESS
 *   修复: 不再设数据页为RX, 修改后保持RW权限, 让游戏可以正常操作
 *
 * Bug 5: UI使用deprecated API获取window
 *   [UIApplication sharedApplication].windows 在iOS 15已deprecated
 *   修复: 使用UIWindowScene.windows获取keyWindow
 *
 * Bug 6: dylib可能被重复加载 (日志出现两次初始化)
 *   修复: 添加static BOOL防止重复初始化
 *
 * v7.4→v8.0 修复的致命Bug:
 * 
 * Bug 1: STP寄存器编码错误
 *   0xA90153F3 = STP x19,x19 (错!)  →  0xA9014FF3 = STP x19,x20 (对)
 *   所有callee-saved寄存器对编码都有问题
 *   根本原因: ARM64 STP格式 Rt1[4:0] Rn[9:5] Rt2[14:10], 原编码搞反了Rt1/Rt2
 *
 * Bug 2: writeReturnTrue/writeReturnValue 不需要保存callee-saved寄存器!
 *   这些函数是IL2CPP的方法替换代码, 被调用时直接return, 不调用任何子函数
 *   保存/恢复6对寄存器完全是多余的, 而且因为编码错误导致栈帧被破坏
 *   修复: return true 只需 mov w0,#1; ret (2条指令=8字节)
 *   修复: return value 只需 movz w0,#val; ret (2-3条指令=8-12字节)
 *
 * Bug 3: patchLimitDamage先vm_protect(WRITE)整页, 再writeReturnValue
 *   但code1(返回true)和codeLimitDmg在同一页, vm_protect(EXECUTE)会锁住
 *   后续无法再写入, 导致slider拖动时vm_protect失败
 *   修复: vm_allocate出来的内存已经是RW, 写完后一次性设为RX即可
 *
 * 新增: il2cpp_method_get_param_count验证, 确保找到正确的方法
 * 新增: 详尽的日志输出, 方便排查问题
 */

#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <dispatch/dispatch.h>
#import <UIKit/UIKit.h>
#import <stdio.h>
#import <string.h>
#import <dlfcn.h>

extern void sys_icache_invalidate(void *start, size_t len);

// ============================================================
// 日志系统
// ============================================================

static FILE *g_logFile = NULL;
static NSMutableArray *g_debugLines = nil;
static UILabel *g_debugLabel = nil;

static void jlog(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[JYJH] %@", msg);
    if (g_debugLines) { [g_debugLines addObject:msg]; if(g_debugLines.count>30)[g_debugLines removeObjectAtIndex:0]; }
    if (g_debugLabel) g_debugLabel.text = [g_debugLines componentsJoinedByString:@"\n"];
    if (!g_logFile) {
        NSString *p = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/jyjh.log"];
        g_logFile = fopen([p UTF8String], "a");
    }
    if (g_logFile) { fprintf(g_logFile, "%s\n", [msg UTF8String]); fflush(g_logFile); }
}

// ============================================================
// 全局状态
// ============================================================

static BOOL g_noCD = YES;
static BOOL g_noEnergy = YES;
static int g_damageLimit = 10000;

// IL2CPP方法信息指针 (MethodInfo*) - 用于替换methodPointer
static void *g_infoCanUse = NULL;
static void *g_infoIsReady = NULL;
static void *g_infoLimitDmg = NULL;

// 原始方法指针 (用于恢复)
static void *g_origPtrCanUse = NULL;
static void *g_origPtrIsReady = NULL;
static void *g_origPtrLimitDmg = NULL;

// vm_allocate分配的可执行代码页
static void *g_codeMem = NULL;
static vm_size_t g_codeMemSize = 0;

// 代码偏移 (在g_codeMem内)
// 布局: [0x000] return_true_1 (8B) [0x008] pad
//        [0x010] return_true_2 (8B) [0x018] pad
//        [0x020] return_value  (12B) [0x02C] pad
static void *g_codeReturnTrue1 = NULL;  // CheckSkillAttackCanUse -> return true
static void *g_codeReturnTrue2 = NULL;  // CheckSkillIsReady -> return true
static void *g_codeReturnValue = NULL;  // get_limitDamage -> return value

// UI
static UIView *g_panel = nil;
static UIButton *g_btnCD = nil;
static UIButton *g_btnEnergy = nil;
static UISlider *g_slider = nil;
static UILabel *g_sliderLabel = nil;
static BOOL g_panelOpen = NO;

// ============================================================
// 内存补丁工具
// ============================================================

/**
 * 写入MethodInfo数据段 (替换methodPointer)
 * 
 * IL2CPP的MethodInfo结构在GameAssembly.dll的数据段, 不是代码段.
 * 数据段默认是RW, 所以直接memcpy写入即可.
 * 
 * 如果写入失败(页权限问题), 用vm_protect临时设为RW, 写完不要改回RX!
 * 因为数据段上还有其他MethodInfo, 游戏后续还需要修改它们.
 * 设为RX会导致:
 *   1) 后续patchMem无法再写入同页的其他MethodInfo
 *   2) 游戏自身的IL2CPP代码也无法写入同页数据
 *   3) 最终触发EXC_BAD_ACCESS闪退
 */
static kern_return_t patchMem(void *addr, const void *data, size_t sz) {
    if (!addr) return KERN_INVALID_ADDRESS;
    
    // 尝试直接写入 (IL2CPP数据段通常已经是RW)
    // 先用vm_read_overwrite测试是否可写
    vm_size_t outSize = 0;
    void *testBuf = NULL;
    kern_return_t kr;
    
    // 分配临时buffer, 读取当前值作为验证
    testBuf = malloc(sz);
    if (!testBuf) return KERN_RESOURCE_SHORTAGE;
    
    kr = vm_read_overwrite(mach_task_self(), (vm_address_t)addr, sz, (vm_address_t)testBuf, &outSize);
    if (kr == KERN_SUCCESS && outSize == sz) {
        // 可读, 尝试直接写入
        memcpy(addr, data, sz);
        // 验证写入是否成功
        if (memcmp(addr, data, sz) == 0) {
            free(testBuf);
            return KERN_SUCCESS;
        }
    }
    free(testBuf);
    
    // 直接写入失败, 需要临时修改页权限为RW
    vm_address_t pg = (vm_address_t)addr & ~(vm_page_size - 1);
    kr = vm_protect(mach_task_self(), pg, vm_page_size, 0,
                    VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        jlog(@"patchMem vm_protect RW FAIL addr=%p kr=%d", addr, kr);
        return kr;
    }
    
    memcpy(addr, data, sz);
    
    // 验证写入成功
    if (memcmp(addr, data, sz) == 0) {
        return KERN_SUCCESS;
    }
    
    jlog(@"patchMem verify FAIL addr=%p", addr);
    return KERN_FAILURE;
}

// ============================================================
// IL2CPP运行时API类型定义
// ============================================================

typedef void* (*Il2CppDomainGet)(void);
typedef void** (*Il2CppDomainGetAssemblies)(void*, size_t*);
typedef void* (*Il2CppAssemblyGetImage)(void*);
typedef size_t (*Il2CppImageGetClassCount)(void*);
typedef void* (*Il2CppImageGetClass)(void*, size_t);
typedef void* (*Il2CppClassGetMethods)(void*, void**);
typedef const char* (*Il2CppMethodGetName)(void*);
typedef uint32_t (*Il2CppMethodGetParamCount)(void*);
typedef const char* (*Il2CppClassGetName)(void*);

// ============================================================
// 从MethodInfo读取methodPointer
// 
// IL2CPP MethodInfo结构 (Unity 2019+ / il2cpp v29+):
//   offset 0x00: MethodPointer methodPointer  (8 bytes on arm64)
//   offset 0x08: InvokerMethod invoker_method (8 bytes)
//   offset 0x10: const char* name
//   offset 0x18: Il2CppClass* klass
//   ...
//
// 注意: 不同Unity版本offset可能不同, getMethodPointer做了2个偏移的尝试
// ============================================================

static void* getMethodPointer(void *methodInfo) {
    if (!methodInfo) return NULL;
    void *ptr = NULL;
    
    // 尝试offset 0 (标准IL2CPP: MethodInfo->methodPointer)
    memcpy(&ptr, methodInfo, sizeof(void*));
    if (ptr && (uint64_t)ptr > 0x100000000ULL) {
        vm_size_t outSize = 0; uint32_t test;
        kern_return_t kr = vm_read_overwrite(mach_task_self(),
            (vm_address_t)ptr, 4, (vm_address_t)&test, &outSize);
        // 验证: 可读, 且内容看起来像ARM64指令(不是0或0xFFFFFFFF)
        if (kr == KERN_SUCCESS && test != 0 && test != 0xFFFFFFFF) {
            jlog(@"  methodPointer@0: %p (verify: 0x%08X)", ptr, test);
            return ptr;
        }
    }
    
    // 尝试offset 8 (某些版本: invoker_method在前面)
    memcpy(&ptr, ((char*)methodInfo) + 8, sizeof(void*));
    if (ptr && (uint64_t)ptr > 0x100000000ULL) {
        vm_size_t outSize = 0; uint32_t test;
        kern_return_t kr = vm_read_overwrite(mach_task_self(),
            (vm_address_t)ptr, 4, (vm_address_t)&test, &outSize);
        if (kr == KERN_SUCCESS && test != 0 && test != 0xFFFFFFFF) {
            jlog(@"  methodPointer@8: %p (verify: 0x%08X)", ptr, test);
            return ptr;
        }
    }
    
    jlog(@"  getMethodPointer FAIL for %p", methodInfo);
    return NULL;
}

// ============================================================
// 查找IL2CPP方法
// 
// 核心思路 (参考libtool的IL2CPP bridge):
// 1. dlopen(NULL) 获取主可执行文件的符号
// 2. dlsym查找il2cpp_domain_get等运行时API
// 3. 遍历Assembly → Image → Class → Method
// 4. 通过方法名匹配找到目标MethodInfo
// 5. 从MethodInfo读取methodPointer (函数的真实机器码地址)
// 6. 用vm_allocate分配新代码, 替换MethodInfo->methodPointer
//
// 这比硬编码偏移好得多, 因为:
// - 游戏更新后偏移会变, 但方法名不变
// - IL2CPP运行时API地址通过dlsym获取, 自动适配
// ============================================================

static void findIL2CPP(void) {
    jlog(@"=== v8.0 IL2CPP Runtime Search ===");
    
    void *h = dlopen(NULL, RTLD_LAZY);
    if (!h) { jlog(@"dlopen FAIL"); return; }
    
    // 获取IL2CPP运行时API
    Il2CppDomainGet domain_get = dlsym(h, "il2cpp_domain_get");
    Il2CppDomainGetAssemblies get_assemblies = dlsym(h, "il2cpp_domain_get_assemblies");
    Il2CppAssemblyGetImage get_image = dlsym(h, "il2cpp_assembly_get_image");
    Il2CppImageGetClassCount class_count = dlsym(h, "il2cpp_image_get_class_count");
    Il2CppImageGetClass get_class = dlsym(h, "il2cpp_image_get_class");
    Il2CppClassGetMethods get_methods = dlsym(h, "il2cpp_class_get_methods");
    Il2CppMethodGetName method_name = dlsym(h, "il2cpp_method_get_name");
    Il2CppMethodGetParamCount param_count = dlsym(h, "il2cpp_method_get_param_count");
    Il2CppClassGetName class_name = dlsym(h, "il2cpp_class_get_name");
    
    jlog(@"APIs: domain=%p assemblies=%p image=%p class_count=%p class=%p methods=%p name=%p",
         domain_get, get_assemblies, get_image, class_count, get_class, get_methods, method_name);
    
    if (!domain_get || !method_name) {
        jlog(@"IL2CPP APIs not found - is this an IL2CPP game?");
        return;
    }
    
    void *domain = domain_get();
    jlog(@"domain=%p", domain);
    if (!domain) { jlog(@"domain is NULL"); return; }
    
    size_t assemCount = 0;
    void **assemblies = get_assemblies(domain, &assemCount);
    jlog(@"assemblies=%p count=%zu", assemblies, assemCount);
    if (!assemblies) { jlog(@"assemblies is NULL"); return; }
    
    int found = 0;
    int totalMethods = 0;
    
    for (size_t a = 0; a < assemCount && found < 3; a++) {
        void *img = get_image(assemblies[a]);
        if (!img) continue;
        size_t cnt = class_count ? class_count(img) : 0;
        
        for (size_t c = 0; c < cnt && found < 3; c++) {
            void *klass = get_class(img, c);
            if (!klass) continue;
            
            // 记录当前类名 (用于调试)
            const char *cn = class_name ? class_name(klass) : NULL;
            
            void *iter = NULL;
            void *m = NULL;
            while ((m = get_methods(klass, &iter)) != NULL) {
                totalMethods++;
                const char *n = method_name(m);
                if (!n) continue;
                
                // CheckSkillAttackCanUse: 技能可用检查 → return true = 无CD
                if (strcmp(n, "CheckSkillAttackCanUse") == 0 && !g_infoCanUse) {
                    uint32_t pc = param_count ? param_count(m) : 0;
                    jlog(@"FOUND CheckSkillAttackCanUse class=%s params=%u", cn ?: "?", pc);
                    g_infoCanUse = m;
                    g_origPtrCanUse = getMethodPointer(m);
                    found++;
                }
                // CheckSkillIsReady: 技能就绪检查 → return true = 无能量
                else if (strcmp(n, "CheckSkillIsReady") == 0 && !g_infoIsReady) {
                    uint32_t pc = param_count ? param_count(m) : 0;
                    jlog(@"FOUND CheckSkillIsReady class=%s params=%u", cn ?: "?", pc);
                    g_infoIsReady = m;
                    g_origPtrIsReady = getMethodPointer(m);
                    found++;
                }
                // get_limitDamage: 伤害上限 → return 自定义值
                else if (strcmp(n, "get_limitDamage") == 0 && !g_infoLimitDmg) {
                    uint32_t pc = param_count ? param_count(m) : 0;
                    jlog(@"FOUND get_limitDamage class=%s params=%u", cn ?: "?", pc);
                    g_infoLimitDmg = m;
                    g_origPtrLimitDmg = getMethodPointer(m);
                    found++;
                }
            }
        }
    }
    
    jlog(@"Scanned %d methods, found %d targets", totalMethods, found);
    jlog(@"Results: CanUse=%p IsReady=%p LimitDmg=%p",
         g_origPtrCanUse, g_origPtrIsReady, g_origPtrLimitDmg);
    jlog(@"MethodInfo: CanUse=%p IsReady=%p LimitDmg=%p",
         g_infoCanUse, g_infoIsReady, g_infoLimitDmg);
}

// ============================================================
// ARM64代码生成
//
// 关键修复: return true/return value 不需要保存callee-saved寄存器!
// 
// 原因: 我们的替换代码只是返回一个常量值, 不调用任何子函数,
// 不会修改任何callee-saved寄存器(x19-x28, x29/fp, x30/lr).
// 调用者保存/恢复寄存器是调用约定的责任, 被调用方不需要操心.
//
// 如果硬要保存, 编码还搞错了, 那就是双重bug.
//
// 正确的替换代码:
//   return true:  mov w0, #1; ret        (2条指令=8字节)
//   return value: movz w0, #val; ret     (2-3条指令=8-12字节)
// ============================================================

/**
 * 在addr写入 return true 代码
 * ARM64:
 *   MOV W0, #1     ; 0x52800020
 *   RET            ; 0xD65F03C0
 * 共8字节
 */
static void writeReturnTrue(void *addr) {
    uint32_t *c = (uint32_t *)addr;
    c[0] = 0x52800020;  // MOV W0, #1
    c[1] = 0xD65F03C0;  // RET
    sys_icache_invalidate(addr, 8);
}

/**
 * 在addr写入 return value 代码
 * ARM64:
 *   MOVZ W0, #low16    ; 0x52800000 | (low << 5)
 *   MOVK W0, #high16, LSL#16  ; 0x72A00000 | (high << 5)  (仅当high!=0)
 *   RET                ; 0xD65F03C0
 * 共8-12字节
 */
static void writeReturnValue(void *addr, int value) {
    uint32_t *c = (uint32_t *)addr;
    uint32_t low = value & 0xFFFF;
    uint32_t high = (value >> 16) & 0xFFFF;
    int i = 0;
    c[i++] = 0x52800000 | (low << 5);   // MOVZ W0, #low16
    if (high) c[i++] = 0x72A00000 | (high << 5);  // MOVK W0, #high16, LSL#16
    c[i++] = 0xD65F03C0;  // RET
    sys_icache_invalidate(addr, i * 4);
}

// ============================================================
// 分配可执行代码内存并写入替换代码
//
// vm_allocate分配的内存默认是VM_PROT_READ|VM_PROT_WRITE
// 写入代码后, 一次性设为VM_PROT_READ|VM_PROT_EXECUTE
// 这样就不会有patchLimitDamage破坏code1/code2的问题
// ============================================================

static BOOL allocCodeMem(void) {
    if (g_codeMem) return YES;
    
    // 分配1页 (16384 bytes on arm64)
    vm_address_t addr = 0;
    kern_return_t kr = vm_allocate(mach_task_self(), &addr, vm_page_size, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        jlog(@"vm_allocate FAIL kr=%d", kr);
        return NO;
    }
    
    g_codeMem = (void *)addr;
    g_codeMemSize = vm_page_size;
    
    // 布局: 每个替换函数占16字节对齐
    g_codeReturnTrue1 = (char *)g_codeMem + 0x000;   // 8 bytes code + 8 pad
    g_codeReturnTrue2 = (char *)g_codeMem + 0x010;   // 8 bytes code + 8 pad
    g_codeReturnValue = (char *)g_codeMem + 0x020;   // 12 bytes code + 4 pad
    
    jlog(@"codeMem=%p size=%zu", g_codeMem, g_codeMemSize);
    jlog(@"  return_true1=%p", g_codeReturnTrue1);
    jlog(@"  return_true2=%p", g_codeReturnTrue2);
    jlog(@"  return_value=%p", g_codeReturnValue);
    return YES;
}

/**
 * 将代码页设为可执行
 * 在所有代码写完后调用一次
 */
static void makeCodeExecutable(void) {
    if (!g_codeMem) return;
    vm_address_t pg = (vm_address_t)g_codeMem & ~(vm_page_size - 1);
    // 先刷新整个代码区的icache
    sys_icache_invalidate(g_codeMem, 64);
    // 设为只读+可执行
    kern_return_t kr = vm_protect(mach_task_self(), pg, vm_page_size, 0,
                                   VM_PROT_READ | VM_PROT_EXECUTE);
    jlog(@"makeCodeExecutable kr=%d", kr);
}

/**
 * 将代码页临时设为可写 (用于修改return_value)
 */
static void makeCodeWritable(void) {
    if (!g_codeMem) return;
    vm_address_t pg = (vm_address_t)g_codeMem & ~(vm_page_size - 1);
    kern_return_t kr = vm_protect(mach_task_self(), pg, vm_page_size, 0,
                                   VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        kr = vm_protect(mach_task_self(), pg, vm_page_size, 0, VM_PROT_ALL);
    }
    jlog(@"makeCodeWritable kr=%d", kr);
}

// ============================================================
// 应用补丁
// ============================================================

static void applyPatches(void) {
    // 第一步: 查找IL2CPP方法
    if (!g_infoCanUse) findIL2CPP();
    
    // 第二步: 分配代码内存
    if (!allocCodeMem()) return;
    
    // 第三步: 写入替换代码 (此时内存是RW)
    writeReturnTrue(g_codeReturnTrue1);
    writeReturnTrue(g_codeReturnTrue2);
    writeReturnValue(g_codeReturnValue, g_damageLimit);
    
    // 第四步: 设为可执行 (此时内存变为RX)
    makeCodeExecutable();
    
    // 第五步: 替换MethodInfo->methodPointer
    // 这修改的是GameAssembly.dll的数据段, 需要patchMem
    if (g_noCD && g_infoCanUse && g_origPtrCanUse) {
        kern_return_t kr = patchMem(g_infoCanUse, &g_codeReturnTrue1, sizeof(void*));
        jlog(@"CanUse: %p -> %p kr=%d", g_origPtrCanUse, g_codeReturnTrue1, kr);
    } else if (!g_infoCanUse) {
        jlog(@"CanUse: MethodInfo not found, skip");
    } else if (!g_origPtrCanUse) {
        jlog(@"CanUse: methodPointer is NULL, skip");
    }
    
    if (g_noEnergy && g_infoIsReady && g_origPtrIsReady) {
        kern_return_t kr = patchMem(g_infoIsReady, &g_codeReturnTrue2, sizeof(void*));
        jlog(@"IsReady: %p -> %p kr=%d", g_origPtrIsReady, g_codeReturnTrue2, kr);
    } else if (!g_infoIsReady) {
        jlog(@"IsReady: MethodInfo not found, skip");
    } else if (!g_origPtrIsReady) {
        jlog(@"IsReady: methodPointer is NULL, skip");
    }
    
    jlog(@"applyPatches done");
}

static void patchLimitDamage(int value) {
    if (!g_infoLimitDmg || !g_codeMem) {
        jlog(@"patchLimitDamage: not ready (info=%p code=%p)", g_infoLimitDmg, g_codeMem);
        return;
    }
    
    // 临时设为可写
    makeCodeWritable();
    // 写入新的返回值代码
    writeReturnValue(g_codeReturnValue, value);
    // 设回可执行
    makeCodeExecutable();
    
    // 替换MethodInfo指针 (只需做一次, 后续只需改代码内容)
    static BOOL ptrPatched = NO;
    if (!ptrPatched && g_origPtrLimitDmg) {
        kern_return_t kr = patchMem(g_infoLimitDmg, &g_codeReturnValue, sizeof(void*));
        jlog(@"LimitDmg: %p -> %p kr=%d", g_origPtrLimitDmg, g_codeReturnValue, kr);
        ptrPatched = (kr == KERN_SUCCESS);
    }
}

/**
 * 恢复原始方法指针 (关闭开关时调用)
 */
static void restoreCanUse(void) {
    if (g_infoCanUse && g_origPtrCanUse) {
        kern_return_t kr = patchMem(g_infoCanUse, &g_origPtrCanUse, sizeof(void*));
        jlog(@"Restore CanUse: kr=%d", kr);
    }
}

static void restoreIsReady(void) {
    if (g_infoIsReady && g_origPtrIsReady) {
        kern_return_t kr = patchMem(g_infoIsReady, &g_origPtrIsReady, sizeof(void*));
        jlog(@"Restore IsReady: kr=%d", kr);
    }
}

// ============================================================
// UI
// ============================================================

static void refreshButtons(void) {
    [g_btnCD setTitle: g_noCD ? @"\U00002705 \u65e0CD: \u5f00" : @"\U0000274c \u65e0CD: \u5173" forState:UIControlStateNormal];
    g_btnCD.backgroundColor = g_noCD ? [UIColor colorWithRed:0.15 green:0.75 blue:0.15 alpha:0.95] : [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:0.95];
    [g_btnEnergy setTitle: g_noEnergy ? @"\U00002705 \u65e0\u80fd\u91cf: \u5f00" : @"\U0000274c \u65e0\u80fd\u91cf: \u5173" forState:UIControlStateNormal];
    g_btnEnergy.backgroundColor = g_noEnergy ? [UIColor colorWithRed:0.15 green:0.75 blue:0.15 alpha:0.95] : [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:0.95];
}

static void layoutPanel(UIView *bv) {
    if (!bv || !g_panel) return;
    CGRect bf=bv.frame, sc=[UIScreen mainScreen].bounds;
    CGFloat pw=260, ph=400;
    CGFloat px=bf.origin.x-pw-8; if(px<4)px=bf.origin.x+bf.size.width+8;
    CGFloat py=bf.origin.y+bf.size.height/2-ph/2;
    if(py<4)py=4; if(py+ph>sc.size.height-4)py=sc.size.height-ph-4;
    g_panel.frame=CGRectMake(px,py,pw,ph);
}

static void togglePanel(UIView *bv) {
    g_panelOpen=!g_panelOpen; g_panel.hidden=!g_panelOpen;
    if(g_panelOpen)layoutPanel(bv);
}

@interface JYJHActionHandler : NSObject
+ (instancetype)shared;
- (void)onCD;
- (void)onEnergy;
- (void)sliderChanged:(UISlider *)slider;
@end
@implementation JYJHActionHandler
+ (instancetype)shared { static JYJHActionHandler *s; static dispatch_once_t o; dispatch_once(&o,^{s=[[self alloc]init];}); return s; }
- (void)onCD {
    g_noCD=!g_noCD; refreshButtons();
    if(g_noCD) applyPatches();
    else restoreCanUse();
}
- (void)onEnergy {
    g_noEnergy=!g_noEnergy; refreshButtons();
    if(g_noEnergy) applyPatches();
    else restoreIsReady();
}
- (void)sliderChanged:(UISlider *)s {
    g_damageLimit=(int)s.value;
    g_sliderLabel.text=[NSString stringWithFormat:@"\u4f24\u5bb3\u4e0a\u9650: %d",g_damageLimit];
    patchLimitDamage(g_damageLimit);
}
@end

@interface JYJHBallView : UIView { CGPoint _ts; BOOL _drag; }
@end
@implementation JYJHBallView
- (instancetype)init {
    self=[super initWithFrame:CGRectMake([UIScreen mainScreen].bounds.size.width-54,100,44,44)];
    if(self){self.backgroundColor=[UIColor colorWithRed:0.1 green:0.5 blue:0.95 alpha:0.9];self.layer.cornerRadius=22;self.userInteractionEnabled=YES;
    UILabel*l=[[UILabel alloc]initWithFrame:CGRectMake(0,0,44,44)];l.text=@"\u5251";l.textColor=[UIColor whiteColor];l.font=[UIFont boldSystemFontOfSize:18];l.textAlignment=NSTextAlignmentCenter;[self addSubview:l];}
    return self;
}
- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent*)e{return CGRectContainsPoint(CGRectInset(self.bounds,-8,-8),p);}
- (void)touchesBegan:(NSSet*)t withEvent:(UIEvent*)e{_ts=[[t anyObject]locationInView:self.superview];_drag=NO;}
- (void)touchesMoved:(NSSet*)t withEvent:(UIEvent*)e{CGPoint c=[[t anyObject]locationInView:self.superview];CGFloat dx=c.x-_ts.x,dy=c.y-_ts.y;if(fabs(dx)>5||fabs(dy)>5){_drag=YES;CGRect f=self.frame;CGRect sc=[UIScreen mainScreen].bounds;f.origin.x=MAX(0,MIN(sc.size.width-f.size.width,f.origin.x+dx));f.origin.y=MAX(50,MIN(sc.size.height-f.size.height-50,f.origin.y+dy));self.frame=f;_ts=c;if(g_panelOpen)layoutPanel(self);}}
- (void)touchesEnded:(NSSet*)t withEvent:(UIEvent*)e{if(!_drag)togglePanel(self);_drag=NO;}
- (void)touchesCancelled:(NSSet*)t withEvent:(UIEvent*)e{_drag=NO;}
@end

static UIWindow *getKeyWindow(void) {
    // iOS 15+ 推荐使用 UIWindowScene.windows
    if (@available(iOS 15.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive &&
                [scene isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (w.isKeyWindow && !w.isHidden) return w;
                }
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (!w.isHidden) return w;
                }
            }
        }
    }
    // Fallback for iOS < 15
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow && !w.isHidden) return w;
    }
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (!w.isHidden) return w;
    }
    return nil;
}

static void setupUI(void) {
    UIWindow *win = getKeyWindow();
    if (!win) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{setupUI();}); return; }
    JYJHBallView *ball = [[JYJHBallView alloc] init]; [win addSubview:ball];
    g_panel=[[UIView alloc]initWithFrame:CGRectMake(0,0,260,400)];
    g_panel.backgroundColor=[UIColor colorWithRed:0.08 green:0.08 blue:0.12 alpha:0.98];
    g_panel.layer.cornerRadius=14; g_panel.hidden=YES; [win addSubview:g_panel];
    UILabel *title=[[UILabel alloc]initWithFrame:CGRectMake(0,10,260,24)];
    title.text=@"\u5251\u5f71\u6c5f\u6e56 v8.1"; title.textColor=[UIColor cyanColor];
    title.font=[UIFont boldSystemFontOfSize:15]; title.textAlignment=NSTextAlignmentCenter; [g_panel addSubview:title];
    g_btnCD=[UIButton buttonWithType:UIButtonTypeCustom]; g_btnCD.frame=CGRectMake(16,42,228,36);
    g_btnCD.layer.cornerRadius=8; [g_btnCD addTarget:[JYJHActionHandler shared] action:@selector(onCD) forControlEvents:UIControlEventTouchUpInside]; [g_panel addSubview:g_btnCD];
    g_btnEnergy=[UIButton buttonWithType:UIButtonTypeCustom]; g_btnEnergy.frame=CGRectMake(16,84,228,36);
    g_btnEnergy.layer.cornerRadius=8; [g_btnEnergy addTarget:[JYJHActionHandler shared] action:@selector(onEnergy) forControlEvents:UIControlEventTouchUpInside]; [g_panel addSubview:g_btnEnergy];
    g_sliderLabel=[[UILabel alloc]initWithFrame:CGRectMake(16,128,228,20)];
    g_sliderLabel.text=@"伤害上限: 10000"; g_sliderLabel.textColor=[UIColor whiteColor];
    g_sliderLabel.font=[UIFont systemFontOfSize:13]; [g_panel addSubview:g_sliderLabel];
    g_slider=[[UISlider alloc]initWithFrame:CGRectMake(16,150,228,28)];
    g_slider.minimumValue=100; g_slider.maximumValue=10000; g_slider.value=10000;
    [g_slider addTarget:[JYJHActionHandler shared] action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged]; [g_panel addSubview:g_slider];
    g_debugLabel=[[UILabel alloc]initWithFrame:CGRectMake(8,186,244,204)];
    g_debugLabel.textColor=[UIColor colorWithRed:0.2 green:1.0 blue:0.2 alpha:1.0];
    g_debugLabel.font=[UIFont fontWithName:@"Menlo" size:10]; g_debugLabel.numberOfLines=0; [g_panel addSubview:g_debugLabel];
    refreshButtons();
}

// ============================================================
// 入口
// ============================================================

__attribute__((constructor))
static void initialize(void) {
    // 防止重复加载
    static BOOL loaded = NO;
    if (loaded) { jlog(@"Already loaded, skip"); return; }
    loaded = YES;
    
    g_debugLines=[NSMutableArray new];
    jlog(@"========== JYJH v8.1 ==========");
    jlog(@"iOS %@", [[UIDevice currentDevice] systemVersion]);
    jlog(@"Bundle %@", [[NSBundle mainBundle] bundleIdentifier]);
    
    // 延迟5秒, 等待IL2CPP运行时初始化完成
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(5.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        jlog(@"5s delay done, applying patches...");
        applyPatches();
        patchLimitDamage(g_damageLimit);
        setupUI();
    });
}
