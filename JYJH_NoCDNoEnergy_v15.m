/**
 * 剑影江湖 v15.0 - TryTriggerExSkill hook策略
 *
 * v14.0日志关键发现:
 *   IsExSkillInCD hook虽然DobbyHook成功, 但从未被调用!
 *   (日志中无"IsExSkillInCD called"输出)
 *   原因: IsExSkillInCD是private函数, TryTriggerExSkill前置检查失败就不调用它
 *
 * v15.0核心变更:
 *   新增hook TryTriggerExSkill (public, 8参数, 地址0x30b88fc)
 *   - 这是大招触发的入口函数, 必然被调用
 *   - 在hook中找到CharacterFiled里的ExSkillData数组, 把怒气值(Data)设为极大值
 *   - 然后调原函数让帧同步逻辑正常执行, 但因为怒气已满, 大招可以释放
 *   - 保留IsExSkillInCD hook但简化为只返回NO(不在CD)
 *
 * TryTriggerExSkill签名:
 *   static Boolean TryTriggerExSkill(
 *     Frame f, x0; ExSkillTriggerType type, x1(UInt64);
 *     EntityRef trigger, x2; EntityRef fuse, x3;
 *     List<EntityRef> targets, x4;
 *     CharacterFiled* character, x5;  <- 关键! 通过它访问ExSkillData
 *     ExSkillsAsset asset, x6; UInt64 triggerData, x7
 *   );
 *
 * ExSkillData值类型偏移(dump.cs偏移-0x10):
 *   lv(Int16)=0x00, id(Int32)=0x04, Data(FP)=0x08(怒气),
 *   LastTriggerTime(FP)=0x10, skills(UInt64)=0x18, 总大小0x20
 * FP格式: Deterministic.FP是64位定点数, RAW_ONE=1<<16, FP(10000)=10000<<16
 */

#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <dispatch/dispatch.h>
#import <UIKit/UIKit.h>
#import <stdio.h>
#import <string.h>
#import <dlfcn.h>

#include "dobby.h"

// ============================================================
// 日志 (仅写文件)
// ============================================================

static FILE *g_logFile = NULL;

static void jlog(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[JYJH] %@", msg);
    if (!g_logFile) {
        NSString *p = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/jyjh.log"];
        g_logFile = fopen([p UTF8String], "a");
    }
    if (g_logFile) { fprintf(g_logFile, "%s\n", [msg UTF8String]); fflush(g_logFile); }
}

// ============================================================
// 全局状态
// ============================================================

static BOOL g_ignoreUnlock = NO;   // 忽略解锁 (默认关)
static BOOL g_exSkillAvail = NO;   // 大招可用 (默认关)
static BOOL g_exSkillNoCD = NO;    // 大招无CD+怒气 (默认关)
static int g_damageLimit = 100;    // 伤害上限

// ============================================================
// 数据结构偏移量
// ============================================================

// ExSkillData字段偏移 (值类型无0x10 header, 实际偏移=dump.cs偏移-0x10)
static const int ESD_LV = 0x00;              // lv (Int16) dump.cs=0x10
static const int ESD_ID = 0x04;              // id (Int32) dump.cs=0x14
static const int ESD_DATA = 0x08;            // Data (FP, 8字节) = 怒气值 dump.cs=0x18
static const int ESD_LASTTRIGGERTIME = 0x10; // LastTriggerTime (FP, 8字节) dump.cs=0x20
static const int ESD_SKILLS = 0x18;          // skills (UInt64) dump.cs=0x28
static const int ESD_SIZE = 0x20;            // ExSkillData总大小 = 32字节

// ============================================================
// Hook函数指针
// ============================================================

typedef BOOL (*BoolFunc3)(void*, int, int);  // 3参数函数
typedef BOOL (*BoolFunc8)(void*, uint64_t, void*, void*, void*, void*, void*, uint64_t);  // 8参数函数(TryTriggerExSkill)
typedef int  (*IntFunc1)(void*);

static void *g_funcCheckSkillUnlock = NULL; static BoolFunc3 g_origCheckSkillUnlock = NULL; static BOOL g_skillUnlockHooked = NO;
static void *g_funcCanUseExSkill = NULL;    static BoolFunc3 g_origCanUseExSkill = NULL;    static BOOL g_canUseExSkillHooked = NO;
static void *g_funcIsExSkillInCD = NULL;    static BoolFunc3 g_origIsExSkillInCD = NULL;    static BOOL g_isExSkillInCDHooked = NO;
static void *g_funcTryTriggerExSkill = NULL; static BoolFunc8 g_origTryTriggerExSkill = NULL; static BOOL g_tryTriggerHooked = NO;
static void *g_funcLimitDmg = NULL;         static IntFunc1 g_origLimitDmg = NULL;          static BOOL g_limitHooked = NO;

// ============================================================
// 辅助函数: 修改ExSkillData怒气值
// ============================================================

/**
 * 修改ExSkillData数组中所有条目的怒气值为极大值
 * @param exSkillDataPtr 指向ExSkillData数组第一个元素的指针
 * @param count 数组元素个数
 *
 * ExSkillData值类型布局 (无header, 实际偏移=dump.cs-0x10):
 *   +0x00: lv (Int16), +0x04: id (Int32), +0x08: Data (FP=怒气)
 *   +0x10: LastTriggerTime (FP), +0x18: skills (UInt64)
 *   总大小: 0x20 (32字节)
 */
static void fillExSkillAnger(void *exSkillDataPtr, int count) {
    if (!exSkillDataPtr || count <= 0) return;

    uint8_t *base = (uint8_t*)exSkillDataPtr;
    for (int i = 0; i < count && i < 10; i++) {
        uint8_t *p = base + i * ESD_SIZE;

        // 读取当前值(用于日志)
        int16_t curLv = *(int16_t*)(p + ESD_LV);
        int32_t curId = *(int32_t*)(p + ESD_ID);
        uint64_t curData = *(uint64_t*)(p + ESD_DATA);

        // 设置怒气值为极大值: FP(10000) = 10000 << 16
        uint64_t maxAnger = (uint64_t)10000 << 16;
        *(uint64_t*)(p + ESD_DATA) = maxAnger;

        // 设置等级为30(解决"等级不够")
        *(int16_t*)(p + ESD_LV) = 30;

        // 清除CD: LastTriggerTime=0
        *(uint64_t*)(p + ESD_LASTTRIGGERTIME) = 0;

        static int fillLogCount = 0;
        if (fillLogCount < 20) {
            fillLogCount++;
            jlog(@"FillAnger[%d] idx=%d: id=%d lv=%d->30 Data=0x%llx->0x%llx",
                 fillLogCount, i, curId, curLv, curData, maxAnger);
        }
    }
}

// ============================================================
// Hook函数实现
// ============================================================

/**
 * [1] 忽略解锁: CheckSkillUnlock → true
 * 签名: (Frame, CharacterFiled*, CharacterStateType) - 3个参数
 * ARM64: self=x0=Frame*, a1=x1=characterField*, a2=x2=stateType
 *
 * 日志验证: a2=18/19(Skill5/6大招), a2=17(Skill4) → stateType确实在a2
 * 用户确认: 忽略解锁对20级普通技能有效, 能用且无CD
 */
static int g_unlockLogCount = 0;
static BOOL hookCheckSkillUnlock(void *self, int a1, int a2) {
    if (g_ignoreUnlock) {
        if (g_unlockLogCount < 5) {
            g_unlockLogCount++;
            jlog(@"Unlock[%d]: stateType=%d", g_unlockLogCount, a2);
        }
        return YES;
    }
    if (g_origCheckSkillUnlock) return g_origCheckSkillUnlock(self, a1, a2);
    return YES;
}

/**
 * [2] 大招可用: CanUseExSkill → true
 * 签名: (Int64 customParam, Int32 usedTimesPack, Int32 exSkillIdx) - 3个参数
 */
static BOOL hookCanUseExSkill(void *self, int a1, int a2) {
    if (g_exSkillAvail) return YES;
    if (g_origCanUseExSkill) return g_origCanUseExSkill(self, a1, a2);
    return YES;
}

/**
 * [3] 大招无CD: IsExSkillInCD → 返回NO(不在CD)
 * v15.0: 简化! 不再在这里修改ExSkillData数据(因为此private函数可能不被调用)
 * 数据修改改在TryTriggerExSkill hook中进行(见下方hookTryTriggerExSkill)
 *
 * 签名: (FP now, ExSkillData* skillp, ExSkillInfo info) - 3个参数
 */
static int g_exSkillLogCount = 0;
static BOOL hookIsExSkillInCD(void *self, int a1, int a2) {
    // 无条件日志: 确认此hook是否被调用
    if (g_exSkillLogCount < 10) {
        g_exSkillLogCount++;
        jlog(@"IsExSkillInCD[%d] called! exNoCD=%d", g_exSkillLogCount, g_exSkillNoCD);
    }

    if (g_exSkillNoCD) {
        return NO; // 不在CD
    }
    if (g_origIsExSkillInCD) return g_origIsExSkillInCD(self, a1, a2);
    return NO;
}

/**
 * [5] 大招怒气加满: TryTriggerExSkill hook
 * 签名: (Frame f, ExSkillTriggerType type, EntityRef trigger,
 *         EntityRef fuse, List<EntityRef> targets,
 *         CharacterFiled* character, ExSkillsAsset asset, UInt64 triggerData)
 * ARM64: x0=Frame*, x1=type(UInt64), x2=trigger, x3=fuse, x4=targets,
 *        x5=CharacterFiled*, x6=asset, x7=triggerData
 *
 * 策略: 在大招触发检查前, 修改ExSkillData.Data为极大值(怒气满)
 *        然后调原函数, 原函数检查怒气时会发现怒气已满, 允许释放
 *
 * 关键: 我们有Frame指针(x0), 可以通过Frame.data + Ptr.Offset访问QListPtr中的ExSkillData
 *
 * 数据访问路径:
 *   Frame* → Frame.data (Frame内部存储, 偏移待确定)
 *   CharacterFiled+0x28 = ExSkillDatasPtr (FrameSync.Ptr, 含Offset)
 *   实际ExSkillData数组 = Frame.data + ExSkillDatasPtr.Offset
 *   QListInternal = 该地址处的QBuffer结构
 *   QBuffer: Length(+0x10), Stride(+0x14), Ptr.Offset(+0x18+0x10)
 *   实际数据 = Frame.data + Ptr.Offset
 *
 * v15.0策略: 先做诊断, 确认TryTriggerExSkill是否被调用, 以及参数是否正确
 *            同时尝试多种方式访问ExSkillData
 */
static int g_tryTriggerLogCount = 0;
static BOOL hookTryTriggerExSkill(void *f, uint64_t type, void *trigger, void *fuse,
                                   void *targets, void *character, void *asset, uint64_t triggerData) {
    // 无条件日志: 确认此函数是否被调用
    if (g_tryTriggerLogCount < 30) {
        g_tryTriggerLogCount++;
        jlog(@"TryTrigger[%d] type=%llu f=%p charPtr=%p noCD=%d",
             g_tryTriggerLogCount, type, f, character, g_exSkillNoCD);
    }

    if (g_exSkillNoCD && character) {
        uint8_t *cf = (uint8_t*)character;

        // === 诊断: dump CharacterFiled内存 ===
        static int cfDumpCount = 0;
        if (cfDumpCount < 3) {
            cfDumpCount++;
            jlog(@"CharacterFiled DUMP ptr=%p:", character);
            for (int off = 0; off < 0x40; off += 8) {
                uint64_t val = *(uint64_t*)(cf + off);
                jlog(@"  +0x%02x: 0x%llx", off, val);
            }
        }

        // === 读取ExSkillDatasPtr (FrameSync.Ptr at CF+0x28) ===
        // FrameSync.Ptr结构: { Offset: Int32 at Ptr+0x10 }
        // 但在值类型嵌入时, 实际只有Offset字段(4字节), 没有header
        // 所以 CF+0x28处直接是Offset值

        // 尝试方案A: CF+0x28直接存储Offset(int32)
        int32_t exDataOffsetA = *(int32_t*)(cf + 0x28);
        jlog(@"ExData OffsetA = %d (0x%x)", exDataOffsetA, exDataOffsetA);

        // 尝试方案B: CF+0x28是8字节(QListPtr), 内含Ptr.Offset at +0x10
        // 即CF+0x28开始的内存当作QListPtr, QListPtr.Ptr.Offset = *(cf+0x28+0x10)
        // 但这看起来不太对...

        // 尝试方案C: CF+0x28存储的是FrameSync.Ptr结构
        // FrameSync.Ptr实际在内存中就是4字节的Offset(int32)
        // 所以CF+0x28 = ExSkillDatas的Offset
        // 实际数据地址 = Frame.data + Offset
        // 但我们不知道Frame.data的基地址...

        // === 替代思路: 直接通过Frame访问 ===
        // Frame指针是x0参数
        // dump Frame内存看看结构
        if (f) {
            static int frameDumpCount = 0;
            if (frameDumpCount < 2) {
                frameDumpCount++;
                uint8_t *fp = (uint8_t*)f;
                jlog(@"Frame DUMP ptr=%p:", f);
                for (int off = 0; off < 0x40; off += 8) {
                    uint64_t val = *(uint64_t*)(fp + off);
                    jlog(@"  +0x%02x: 0x%llx", off, val);
                }
            }

            // 尝试: Frame可能有一个data字段
            // 帧同步架构中, Frame.data是所有帧同步数据的基地址
            // 常见的Frame结构: { tick, ... , data_ptr }
            // 但具体偏移需要逆向

            // 如果exDataOffsetA看起来像合理的偏移(0 < offset < 1MB)
            // 且Frame有data指针, 我们可以尝试:
            // 1. 从Frame中找到data指针
            // 2. data_ptr + exDataOffsetA = QListInternal*
            // 3. 从QListInternal中读取ExSkillData数组

            if (exDataOffsetA > 0 && exDataOffsetA < 0x100000) {
                // Offset看起来合理, 尝试在Frame中寻找data基地址
                // 常见Frame.data偏移: 0x08, 0x10, 0x18等
                uint8_t *fp = (uint8_t*)f;
                for (int dataOff = 0x08; dataOff <= 0x30; dataOff += 0x08) {
                    void *possibleDataPtr = *(void**)(fp + dataOff);
                    if (possibleDataPtr && (uintptr_t)possibleDataPtr > 0x100000000ULL) {
                        // 看起来像64位堆指针
                        uint8_t *targetAddr = (uint8_t*)possibleDataPtr + exDataOffsetA;

                        // 安全检查
                        vm_size_t sz = 0;
                        vm_address_t addr = (vm_address_t)targetAddr;
                        vm_region_basic_info_data_64_t info;
                        mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
                        kern_return_t kr = vm_region_64(mach_task_self(), &addr, &sz, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &cnt, NULL);

                        if (kr == KERN_SUCCESS) {
                            // 可读! 尝试解析为QListInternal
                            int32_t length = *(int32_t*)(targetAddr + 0x10);
                            int32_t stride = *(int32_t*)(targetAddr + 0x14);
                            int32_t dataOffset2 = *(int32_t*)(targetAddr + 0x18 + 0x10);

                            jlog(@"Frame+0x%x=%p -> QLI(%p): Len=%d Stride=%d DataOff2=%d",
                                 dataOff, possibleDataPtr, targetAddr, length, stride, dataOffset2);

                            // 如果length合理(1-10个ExSkillData)且stride=0x20
                            if (length > 0 && length <= 10 && stride == ESD_SIZE) {
                                // 找到了! dataOffset2是ExSkillData数组的偏移
                                uint8_t *exSkillDataAddr = (uint8_t*)possibleDataPtr + dataOffset2;

                                // 安全检查
                                addr = (vm_address_t)exSkillDataAddr;
                                kr = vm_region_64(mach_task_self(), &addr, &sz, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &cnt, NULL);
                                if (kr == KERN_SUCCESS) {
                                    jlog(@"FOUND ExSkillData at %p (Frame+0x%x->%p+%d+%d) count=%d",
                                         exSkillDataAddr, dataOff, possibleDataPtr, exDataOffsetA, dataOffset2, length);

                                    // dump第一个ExSkillData
                                    jlog(@"ExSkillData[0] DUMP:");
                                    uint8_t *p = exSkillDataAddr;
                                    jlog(@"  +00: %02x %02x %02x %02x  %02x %02x %02x %02x  %02x %02x %02x %02x  %02x %02x %02x %02x",
                                         p[0],p[1],p[2],p[3],p[4],p[5],p[6],p[7],
                                         p[8],p[9],p[10],p[11],p[12],p[13],p[14],p[15]);
                                    jlog(@"  +10: %02x %02x %02x %02x  %02x %02x %02x %02x  %02x %02x %02x %02x  %02x %02x %02x %02x",
                                         p[16],p[17],p[18],p[19],p[20],p[21],p[22],p[23],
                                         p[24],p[25],p[26],p[27],p[28],p[29],p[30],p[31]);

                                    // 修改怒气值!
                                    fillExSkillAnger(exSkillDataAddr, length);

                                    // 只需要成功一次
                                    break;
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // 调原函数
    if (g_origTryTriggerExSkill) {
        return g_origTryTriggerExSkill(f, type, trigger, fuse, targets, character, asset, triggerData);
    }
    return NO;
}

/** [4] 伤害上限: get_limitDamage → g_damageLimit */
static int hookLimitDmg(void *self) {
    return g_damageLimit;
}

// ============================================================
// IL2CPP运行时API
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
// 查找IL2CPP方法
// ============================================================

static void findIL2CPP(void) {
    jlog(@"=== v15.0 IL2CPP Runtime Search ===");

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
    Il2CppClassGetName class_name_func = dlsym(h, "il2cpp_class_get_name");

    if (!domain_get || !method_name) { jlog(@"IL2CPP APIs not found"); return; }

    void *domain = domain_get();
    if (!domain) return;

    size_t assemCount = 0;
    void **assemblies = get_assemblies(domain, &assemCount);
    if (!assemblies) return;

    jlog(@"assemblies=%p count=%zu", assemblies, assemCount);

    int found = 0;
    int totalMethods = 0;

    for (size_t a = 0; a < assemCount; a++) {
        void *img = get_image(assemblies[a]);
        if (!img) continue;
        size_t cnt = class_count ? class_count(img) : 0;

        for (size_t c = 0; c < cnt; c++) {
            void *klass = get_class(img, c);
            if (!klass) continue;
            const char *cn = class_name_func ? class_name_func(klass) : NULL;

            void *iter = NULL;
            void *m = NULL;
            while ((m = get_methods(klass, &iter)) != NULL) {
                totalMethods++;
                const char *n = method_name(m);
                if (!n) continue;

                uint32_t pc = param_count ? param_count(m) : 0;
                void *funcAddr = NULL;
                memcpy(&funcAddr, m, sizeof(void*));

                // v15.0: 搜索5个安全函数 + TryTriggerExSkill
                if (strcmp(n, "CheckSkillUnlock") == 0 && !g_funcCheckSkillUnlock) {
                    jlog(@"FOUND %s.CheckSkillUnlock params=%u addr=%p [1.忽略解锁]", cn ?: "?", pc, funcAddr);
                    g_funcCheckSkillUnlock = funcAddr; found++;
                }
                else if (strcmp(n, "CanUseExSkill") == 0 && !g_funcCanUseExSkill) {
                    jlog(@"FOUND %s.CanUseExSkill params=%u addr=%p [2.大招可用]", cn ?: "?", pc, funcAddr);
                    g_funcCanUseExSkill = funcAddr; found++;
                }
                else if (strcmp(n, "IsExSkillInCD") == 0 && !g_funcIsExSkillInCD) {
                    jlog(@"FOUND %s.IsExSkillInCD params=%u addr=%p [3.大招无CD]", cn ?: "?", pc, funcAddr);
                    g_funcIsExSkillInCD = funcAddr; found++;
                }
                else if (strcmp(n, "TryTriggerExSkill") == 0 && !g_funcTryTriggerExSkill) {
                    jlog(@"FOUND %s.TryTriggerExSkill params=%u addr=%p [5.怒气加满]", cn ?: "?", pc, funcAddr);
                    g_funcTryTriggerExSkill = funcAddr; found++;
                }
                else if (strcmp(n, "get_limitDamage") == 0 && !g_funcLimitDmg) {
                    jlog(@"FOUND %s.get_limitDamage params=%u addr=%p [4.伤害上限]", cn ?: "?", pc, funcAddr);
                    g_funcLimitDmg = funcAddr; found++;
                }
            }
        }
    }

    jlog(@"Scanned %d methods, found %d targets", totalMethods, found);
    jlog(@"[1]Unlock=%p [2]CanUse=%p [3]IsCD=%p [4]LimitDmg=%p [5]TryTrigger=%p",
         g_funcCheckSkillUnlock, g_funcCanUseExSkill, g_funcIsExSkillInCD, g_funcLimitDmg, g_funcTryTriggerExSkill);
}

// ============================================================
// Dobby Hook 操作
// ============================================================

static void hookOneFunc(void *funcAddr, void *hookFunc, void **origFunc, BOOL *hookedFlag, const char *name) {
    if (!funcAddr) { jlog(@"%s: funcAddr not found, skip", name); return; }
    if (*hookedFlag) { jlog(@"%s: already hooked", name); return; }
    int ret = DobbyHook(funcAddr, hookFunc, origFunc);
    if (ret == 0) {
        *hookedFlag = YES;
        jlog(@"%s: DobbyHook OK at %p, orig=%p", name, funcAddr, *origFunc);
    } else {
        jlog(@"%s: DobbyHook FAILED ret=%d addr=%p", name, ret, funcAddr);
    }
}

static void applyAllHooks(void) {
    if (!g_funcCheckSkillUnlock) findIL2CPP();

    // 只安装伤害上限(默认开启), 其余惰性安装
    hookOneFunc(g_funcLimitDmg, hookLimitDmg, (void**)&g_origLimitDmg, &g_limitHooked, "4.伤害上限");

    jlog(@"applyAllHooks done hooked: Unlock=%d ExAvail=%d ExNoCD=%d TryTrigger=%d Limit=%d",
         g_skillUnlockHooked, g_canUseExSkillHooked, g_isExSkillInCDHooked, g_tryTriggerHooked, g_limitHooked);
}

// ============================================================
// UI
// ============================================================

static UIView *g_panel = nil;
static UIButton *g_btnIgnoreUnlock = nil;
static UIButton *g_btnExSkillAvail = nil;
static UIButton *g_btnExSkillNoCD = nil;
static UISlider *g_slider = nil;
static UILabel *g_sliderLabel = nil;
static BOOL g_panelOpen = NO;

static void refreshButtons(void) {
    [g_btnIgnoreUnlock setTitle: g_ignoreUnlock ? @"\U00002705 \u5ffd\u7565\u89e3\u9501" : @"\U0000274c \u5ffd\u7565\u89e3\u9501" forState:UIControlStateNormal];
    g_btnIgnoreUnlock.backgroundColor = g_ignoreUnlock ? [UIColor colorWithRed:0.15 green:0.75 blue:0.15 alpha:0.95] : [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:0.95];

    [g_btnExSkillAvail setTitle: g_exSkillAvail ? @"\U00002705 \u5927\u62db\u53ef\u7528" : @"\U0000274c \u5927\u62db\u53ef\u7528" forState:UIControlStateNormal];
    g_btnExSkillAvail.backgroundColor = g_exSkillAvail ? [UIColor colorWithRed:0.15 green:0.75 blue:0.15 alpha:0.95] : [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:0.95];

    [g_btnExSkillNoCD setTitle: g_exSkillNoCD ? @"\U00002705 \u5927\u62db\u65e0CD" : @"\U0000274c \u5927\u62cd\u65e0CD" forState:UIControlStateNormal];
    g_btnExSkillNoCD.backgroundColor = g_exSkillNoCD ? [UIColor colorWithRed:0.15 green:0.75 blue:0.15 alpha:0.95] : [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:0.95];
}

static void layoutPanel(UIView *bv) {
    if (!bv || !g_panel) return;
    CGRect bf=bv.frame, sc=[UIScreen mainScreen].bounds;
    CGFloat pw=260, ph=240;
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
- (void)onIgnoreUnlock;
- (void)onExSkillAvail;
- (void)onExSkillNoCD;
- (void)sliderChanged:(UISlider *)slider;
@end
@implementation JYJHActionHandler
+ (instancetype)shared { static JYJHActionHandler *s; static dispatch_once_t o; dispatch_once(&o,^{s=[[self alloc]init];}); return s; }
- (void)onIgnoreUnlock {
    g_ignoreUnlock=!g_ignoreUnlock;
    if (g_ignoreUnlock && !g_skillUnlockHooked) {
        findIL2CPP();
        hookOneFunc(g_funcCheckSkillUnlock, hookCheckSkillUnlock, (void**)&g_origCheckSkillUnlock, &g_skillUnlockHooked, "1.忽略解锁");
    }
    refreshButtons(); jlog(@"Toggle 忽略解锁: %d hooked=%d", g_ignoreUnlock, g_skillUnlockHooked);
}
- (void)onExSkillAvail {
    g_exSkillAvail=!g_exSkillAvail;
    if (g_exSkillAvail && !g_canUseExSkillHooked) {
        findIL2CPP();
        hookOneFunc(g_funcCanUseExSkill, hookCanUseExSkill, (void**)&g_origCanUseExSkill, &g_canUseExSkillHooked, "2.大招可用");
    }
    refreshButtons(); jlog(@"Toggle 大招可用: %d hooked=%d", g_exSkillAvail, g_canUseExSkillHooked);
}
- (void)onExSkillNoCD {
    g_exSkillNoCD=!g_exSkillNoCD;
    if (g_exSkillNoCD) {
        findIL2CPP();
        // 安装IsExSkillInCD hook (返回NO=不在CD)
        if (!g_isExSkillInCDHooked) {
            hookOneFunc(g_funcIsExSkillInCD, hookIsExSkillInCD, (void**)&g_origIsExSkillInCD, &g_isExSkillInCDHooked, "3.大招无CD");
        }
        // 安装TryTriggerExSkill hook (修改怒气值)
        if (!g_tryTriggerHooked) {
            hookOneFunc(g_funcTryTriggerExSkill, hookTryTriggerExSkill, (void**)&g_origTryTriggerExSkill, &g_tryTriggerHooked, "5.怒气加满");
        }
    }
    refreshButtons(); jlog(@"Toggle 大招无CD: %d hooked: IsCD=%d TryTrigger=%d", g_exSkillNoCD, g_isExSkillInCDHooked, g_tryTriggerHooked);
}
- (void)sliderChanged:(UISlider *)s {
    g_damageLimit=(int)s.value;
    g_sliderLabel.text=[NSString stringWithFormat:@"\u4f24\u5bb3\u4e0a\u9650: %d",g_damageLimit];
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
    return nil;
}

static void setupUI(void) {
    UIWindow *win = getKeyWindow();
    if (!win) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{setupUI();}); return; }
    JYJHBallView *ball = [[JYJHBallView alloc] init]; [win addSubview:ball];

    CGFloat pw=260, ph=240;
    g_panel=[[UIView alloc]initWithFrame:CGRectMake(0,0,pw,ph)];
    g_panel.backgroundColor=[UIColor colorWithRed:0.08 green:0.08 blue:0.12 alpha:0.98];
    g_panel.layer.cornerRadius=14; g_panel.hidden=YES; [win addSubview:g_panel];

    UILabel *title=[[UILabel alloc]initWithFrame:CGRectMake(0,8,pw,22)];
    title.text=@"\u5251\u5f71\u6c5f\u6e56 v15.0"; title.textColor=[UIColor cyanColor];
    title.font=[UIFont boldSystemFontOfSize:14]; title.textAlignment=NSTextAlignmentCenter; [g_panel addSubview:title];

    CGFloat bx=16, bw=228, bh=32, by0=34, bdy=36;
    g_btnIgnoreUnlock=[UIButton buttonWithType:UIButtonTypeCustom]; g_btnIgnoreUnlock.frame=CGRectMake(bx,by0,bw,bh);
    g_btnIgnoreUnlock.layer.cornerRadius=8; g_btnIgnoreUnlock.titleLabel.font=[UIFont boldSystemFontOfSize:13];
    [g_btnIgnoreUnlock addTarget:[JYJHActionHandler shared] action:@selector(onIgnoreUnlock) forControlEvents:UIControlEventTouchUpInside]; [g_panel addSubview:g_btnIgnoreUnlock];

    g_btnExSkillAvail=[UIButton buttonWithType:UIButtonTypeCustom]; g_btnExSkillAvail.frame=CGRectMake(bx,by0+bdy,bw,bh);
    g_btnExSkillAvail.layer.cornerRadius=8; g_btnExSkillAvail.titleLabel.font=[UIFont boldSystemFontOfSize:13];
    [g_btnExSkillAvail addTarget:[JYJHActionHandler shared] action:@selector(onExSkillAvail) forControlEvents:UIControlEventTouchUpInside]; [g_panel addSubview:g_btnExSkillAvail];

    g_btnExSkillNoCD=[UIButton buttonWithType:UIButtonTypeCustom]; g_btnExSkillNoCD.frame=CGRectMake(bx,by0+bdy*2,bw,bh);
    g_btnExSkillNoCD.layer.cornerRadius=8; g_btnExSkillNoCD.titleLabel.font=[UIFont boldSystemFontOfSize:13];
    [g_btnExSkillNoCD addTarget:[JYJHActionHandler shared] action:@selector(onExSkillNoCD) forControlEvents:UIControlEventTouchUpInside]; [g_panel addSubview:g_btnExSkillNoCD];

    CGFloat sy = by0 + bdy*3 + 4;
    g_sliderLabel=[[UILabel alloc]initWithFrame:CGRectMake(bx,sy,bw,18)];
    g_sliderLabel.text=[NSString stringWithFormat:@"\u4f24\u5bb3\u4e0a\u9650: %d", g_damageLimit];
    g_sliderLabel.textColor=[UIColor whiteColor]; g_sliderLabel.font=[UIFont systemFontOfSize:12]; [g_panel addSubview:g_sliderLabel];

    g_slider=[[UISlider alloc]initWithFrame:CGRectMake(bx,sy+20,bw,28)];
    g_slider.minimumValue=100; g_slider.maximumValue=30000; g_slider.value=g_damageLimit;
    [g_slider addTarget:[JYJHActionHandler shared] action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged]; [g_panel addSubview:g_slider];

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

    jlog(@"========== JYJH v15.0 (TryTriggerExSkill hook) ==========");
    jlog(@"iOS %@", [[UIDevice currentDevice] systemVersion]);
    jlog(@"Bundle %@", [[NSBundle mainBundle] bundleIdentifier]);
    jlog(@"v15.0: 新增TryTriggerExSkill hook(怒气加满) + IsExSkillInCD(返回NO)");
    jlog(@"  保留: 忽略解锁/大招可用/伤害上限");
    jlog(@"  完全不hook帧同步关键路径函数(CheckSkillAttackCanUse/CheckSkillIsReady)");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(5.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        jlog(@"5s delay done, applying hooks...");
        applyAllHooks();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            setupUI();
        });
    });
}
