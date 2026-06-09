/**
 * 剑影江湖 v8.2 - IL2CPP运行时方法指针替换
 * 
 * v8.1→v8.2 修复的Bug:
 * 
 * Bug 7 (闪退): applyPatches()在toggle ON时重写代码页(RX→RW→写→RX)
 *   toggle OFF→ON时, 代码页已经是RX, applyPatches尝试写代码到RX页→EXC_BAD_ACCESS
 *   修复: applyPatches只替换methodPointer, 不重写代码页
 *         代码页在初始化时一次性写好, 之后只通过patchLimitDamage修改return_value区域
 *
 * Bug 8 (闪退): makeCodeExecutable把代码页设为RX, 但slider拖动需要RW
 *   makeCodeWritable(RX→RW)和makeCodeExecutable(RW→RX)频繁切换
 *   在切换期间如果游戏调用替换代码, RX→RW瞬间代码不可执行→crash
 *   修复: 代码页设为RWX (VM_PROT_READ|VM_PROT_WRITE|VM_PROT_EXECUTE)
 *         这是用户空间内存, 安全性不是问题; 避免RW↔RX切换的竞态条件
 *
 * Bug 9 (伤害无效): get_limitDamage是C#属性getter, 替换methodPointer后
 *   IL2CPP的invoker仍然用原签名调用, 0参数方法返回值被正确处理
 *   真实原因: patchLimitDamage中static ptrPatched在游戏重启后不重置
 *   但更关键的是: 需要确认代码页是否可写再修改
 *   修复: 统一使用RWX权限, 消除写入失败的可能性
 *
 * v8.0→v8.1 修复:
 *   Bug 4: patchMem把数据页设为RX导致闪退 → 保持RW
 *   Bug 5: UI用deprecated windows API → UIWindowScene
 *   Bug 6: dylib重复加载 → static guard
 *
 * v7.4→v8.0 修复:
 *   Bug 1-3: STP编码/寄存器保存/vm_protect竞态
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

// vm_allocate分配的可执行代码页 (RWX权限, 不需要切换)
static void *g_codeMem = NULL;
static vm_size_t g_codeMemSize = 0;

// 代码偏移 (在g_codeMem内)
// 布局: [0x000] return_true_1 (8B) [0x008] pad
//        [0x010] return_true_2 (8B) [0x018] pad
//        [0x020] return_value  (12B) [0x02C] pad
static void *g_codeReturnTrue1 = NULL;  // CheckSkillAttackCanUse -> return true
static void *g_codeReturnTrue2 = NULL;  // CheckSkillIsReady -> return true
static void *g_codeReturnValue = NULL;  // get_limitDamage -> return value

// 伤害上限是否已patch
static BOOL g_limitDmgPatched = NO;

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
 * 写完后不要改回RX! 数据段需要保持可写.
 */
static kern_return_t patchMem(void *addr, const void *data, size_t sz) {
    if (!addr) return KERN_INVALID_ADDRESS;
    
    // 尝试直接写入 (IL2CPP数据段通常已经是RW)
    memcpy(addr, data, sz);
    if (memcmp(addr, data, sz) == 0) {
        return KERN_SUCCESS;
    }
    
    // 直接写入失败, 需要修改页权限为RW
    vm_address_t pg = (vm_address_t)addr & ~(vm_page_size - 1);
    kern_return_t kr = vm_protect(mach_task_self(), pg, vm_page_size, 0,
                                   VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        jlog(@"patchMem vm_protect RW FAIL addr=%p kr=%d", addr, kr);
        return kr;
    }
    
    memcpy(addr, data, sz);
    
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

/**
 * dumpMethodInfo - 打印MethodInfo结构的前64字节
 * 用于调试methodPointer偏移是否正确
 */
static void dumpMethodInfo(const char *label, void *methodInfo) {
    if (!methodInfo) { jlog(@"%s: NULL", label); return; }
    
    uint64_t *p = (uint64_t *)methodInfo;
    jlog(@"=== dump %s MethodInfo @ %p ===", label, methodInfo);
    for (int i = 0; i < 8; i++) {
        jlog(@"  [%d] +0x%02X: 0x%016llX", i, i*8, (unsigned long long)p[i]);
    }
    
    // 读取每个8字节作为指针, 验证是否指向可执行代码
    for (int i = 0; i < 4; i++) {
        void *ptr = (void *)p[i];
        if (ptr && (uint64_t)ptr > 0x100000000ULL) {
            vm_size_t outSize = 0; uint32_t test;
            kern_return_t kr = vm_read_overwrite(mach_task_self(),
                (vm_address_t)ptr, 4, (vm_address_t)&test, &outSize);
            if (kr == KERN_SUCCESS && test != 0 && test != 0xFFFFFFFF) {
                jlog(@"  -> offset %d (%p) looks like code: 0x%08X", i, ptr, test);
            }
        }
    }
}

// ============================================================
// 查找IL2CPP方法
// ============================================================

static void findIL2CPP(void) {
    jlog(@"=== v8.2 IL2CPP Runtime Search ===");
    
    void *h = dlopen(NULL, RTLD_LAZY);
    if (!h) { jlog(@"dlopen FAIL"); return; }
    
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
            
            const char *cn = class_name ? class_name(klass) : NULL;
            
            void *iter = NULL;
            void *m = NULL;
            while ((m = get_methods(klass, &iter)) != NULL) {
                totalMethods++;
                const char *n = method_name(m);
                if (!n) continue;
                
                if (strcmp(n, "CheckSkillAttackCanUse") == 0 && !g_infoCanUse) {
                    uint32_t pc = param_count ? param_count(m) : 0;
                    jlog(@"FOUND CheckSkillAttackCanUse class=%s params=%u", cn ?: "?", pc);
                    g_infoCanUse = m;
                    g_origPtrCanUse = getMethodPointer(m);
                    found++;
                }
                else if (strcmp(n, "CheckSkillIsReady") == 0 && !g_infoIsReady) {
                    uint32_t pc = param_count ? param_count(m) : 0;
                    jlog(@"FOUND CheckSkillIsReady class=%s params=%u", cn ?: "?", pc);
                    g_infoIsReady = m;
                    g_origPtrIsReady = getMethodPointer(m);
                    found++;
                }
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
// ============================================================

static void writeReturnTrue(void *addr) {
    uint32_t *c = (uint32_t *)addr;
    c[0] = 0x52800020;  // MOV W0, #1
    c[1] = 0xD65F03C0;  // RET
    sys_icache_invalidate(addr, 8);
}

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
// 分配可执行代码内存
//
// v8.2关键改进: 使用RWX权限, 避免RW↔RX切换的竞态条件
// 
// 之前: 初始化时RW→写代码→RX, slider时RX→RW→写→RX
// 问题: RX→RW瞬间, 如果游戏调用替换代码→EXC_BAD_ACCESS
//       RX→RW→RX频繁切换, 在切换窗口期crash
// 修复: 一次性设为RWX, 永远不需要切换权限
//       安全性不是问题: 这是用户空间内存, 不涉及系统安全
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
    
    // 设为RWX - 一次性, 之后永远不需要切换权限
    kr = vm_protect(mach_task_self(), addr, vm_page_size, 0,
                    VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) {
        jlog(@"vm_protect RWX FAIL kr=%d, trying VM_PROT_ALL", kr);
        kr = vm_protect(mach_task_self(), addr, vm_page_size, 0, VM_PROT_ALL);
        if (kr != KERN_SUCCESS) {
            jlog(@"vm_protect VM_PROT_ALL FAIL kr=%d", kr);
            vm_deallocate(mach_task_self(), addr, vm_page_size);
            g_codeMem = NULL;
            return NO;
        }
    }
    
    // 布局: 每个替换函数占16字节对齐
    g_codeReturnTrue1 = (char *)g_codeMem + 0x000;
    g_codeReturnTrue2 = (char *)g_codeMem + 0x010;
    g_codeReturnValue = (char *)g_codeMem + 0x020;
    
    // 一次性写入所有替换代码
    writeReturnTrue(g_codeReturnTrue1);
    writeReturnTrue(g_codeReturnTrue2);
    writeReturnValue(g_codeReturnValue, g_damageLimit);
    
    jlog(@"codeMem=%p size=%zu (RWX)", g_codeMem, g_codeMemSize);
    jlog(@"  return_true1=%p", g_codeReturnTrue1);
    jlog(@"  return_true2=%p", g_codeReturnTrue2);
    jlog(@"  return_value=%p", g_codeReturnValue);
    return YES;
}

// ============================================================
// 应用补丁 - 只替换methodPointer, 不重写代码
// ============================================================

static void applyCanUse(BOOL enable) {
    if (!g_infoCanUse) return;
    
    // 验证: 读取MethodInfo的第一个8字节, 看当前值
    void *currentPtr = NULL;
    memcpy(&currentPtr, g_infoCanUse, sizeof(void*));
    jlog(@"CanUse current methodPointer=%p (expect %s)", currentPtr, enable ? "return_true1" : "origPtr");
    
    if (enable) {
        kern_return_t kr = patchMem(g_infoCanUse, &g_codeReturnTrue1, sizeof(void*));
        jlog(@"CanUse: ON (%p -> %p) kr=%d", g_origPtrCanUse, g_codeReturnTrue1, kr);
        
        // 验证写入: 读回第一个8字节
        void *verifyPtr = NULL;
        memcpy(&verifyPtr, g_infoCanUse, sizeof(void*));
        jlog(@"CanUse verify: methodPointer now=%p (expect %p) match=%d",
             verifyPtr, g_codeReturnTrue1, verifyPtr == g_codeReturnTrue1);
    } else {
        kern_return_t kr = patchMem(g_infoCanUse, &g_origPtrCanUse, sizeof(void*));
        jlog(@"CanUse: OFF (restore %p) kr=%d", g_origPtrCanUse, kr);
        
        // 验证恢复
        void *verifyPtr = NULL;
        memcpy(&verifyPtr, g_infoCanUse, sizeof(void*));
        jlog(@"CanUse verify: methodPointer now=%p (expect %p) match=%d",
             verifyPtr, g_origPtrCanUse, verifyPtr == g_origPtrCanUse);
    }
}

static void applyIsReady(BOOL enable) {
    if (!g_infoIsReady) return;
    
    void *currentPtr = NULL;
    memcpy(&currentPtr, g_infoIsReady, sizeof(void*));
    jlog(@"IsReady current methodPointer=%p", currentPtr);
    
    if (enable) {
        kern_return_t kr = patchMem(g_infoIsReady, &g_codeReturnTrue2, sizeof(void*));
        jlog(@"IsReady: ON (%p -> %p) kr=%d", g_origPtrIsReady, g_codeReturnTrue2, kr);
        
        void *verifyPtr = NULL;
        memcpy(&verifyPtr, g_infoIsReady, sizeof(void*));
        jlog(@"IsReady verify: methodPointer now=%p (expect %p) match=%d",
             verifyPtr, g_codeReturnTrue2, verifyPtr == g_codeReturnTrue2);
    } else {
        kern_return_t kr = patchMem(g_infoIsReady, &g_origPtrIsReady, sizeof(void*));
        jlog(@"IsReady: OFF (restore %p) kr=%d", g_origPtrIsReady, kr);
        
        void *verifyPtr = NULL;
        memcpy(&verifyPtr, g_infoIsReady, sizeof(void*));
        jlog(@"IsReady verify: methodPointer now=%p (expect %p) match=%d",
             verifyPtr, g_origPtrIsReady, verifyPtr == g_origPtrIsReady);
    }
}

static void applyLimitDmg(BOOL enable) {
    if (!g_infoLimitDmg) return;
    
    if (enable) {
        kern_return_t kr = patchMem(g_infoLimitDmg, &g_codeReturnValue, sizeof(void*));
        jlog(@"LimitDmg: ON (%p -> %p) kr=%d", g_origPtrLimitDmg, g_codeReturnValue, kr);
        g_limitDmgPatched = YES;
        
        // 验证
        void *verifyPtr = NULL;
        memcpy(&verifyPtr, g_infoLimitDmg, sizeof(void*));
        jlog(@"LimitDmg verify: methodPointer now=%p (expect %p) match=%d",
             verifyPtr, g_codeReturnValue, verifyPtr == g_codeReturnValue);
    } else {
        kern_return_t kr = patchMem(g_infoLimitDmg, &g_origPtrLimitDmg, sizeof(void*));
        jlog(@"LimitDmg: OFF (restore %p) kr=%d", g_origPtrLimitDmg, kr);
        g_limitDmgPatched = NO;
    }
}

static void applyAllPatches(void) {
    // 第一步: 查找IL2CPP方法
    if (!g_infoCanUse) findIL2CPP();
    
    // 第二步: 分配代码内存并写入替换代码 (RWX)
    if (!allocCodeMem()) return;
    
    // 第二步B: dump MethodInfo结构, 确认methodPointer偏移
    dumpMethodInfo("CanUse", g_infoCanUse);
    dumpMethodInfo("IsReady", g_infoIsReady);
    dumpMethodInfo("LimitDmg", g_infoLimitDmg);
    
    // 第三步: 替换methodPointer
    if (g_noCD) applyCanUse(YES);
    if (g_noEnergy) applyIsReady(YES);
    applyLimitDmg(YES);
    
    jlog(@"applyAllPatches done");
}

static void patchLimitDamage(int value) {
    if (!g_codeReturnValue || !g_codeMem) {
        jlog(@"patchLimitDamage: not ready");
        return;
    }
    
    // RWX权限, 直接写, 无需切换权限
    writeReturnValue(g_codeReturnValue, value);
    
    // 如果还没替换methodPointer, 现在替换
    if (!g_limitDmgPatched && g_infoLimitDmg) {
        applyLimitDmg(YES);
    }
    
    jlog(@"patchLimitDamage: value=%d", value);
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
    // 只切换methodPointer, 不重写代码页
    applyCanUse(g_noCD);
}
- (void)onEnergy {
    g_noEnergy=!g_noEnergy; refreshButtons();
    applyIsReady(g_noEnergy);
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
    title.text=@"\u5251\u5f71\u6c5f\u6e56 v8.3"; title.textColor=[UIColor cyanColor];
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
    static BOOL loaded = NO;
    if (loaded) { jlog(@"Already loaded, skip"); return; }
    loaded = YES;
    
    g_debugLines=[NSMutableArray new];
    jlog(@"========== JYJH v8.3 ==========");
    jlog(@"iOS %@", [[UIDevice currentDevice] systemVersion]);
    jlog(@"Bundle %@", [[NSBundle mainBundle] bundleIdentifier]);
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(5.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        jlog(@"5s delay done, applying patches...");
        applyAllPatches();
        setupUI();
    });
}
