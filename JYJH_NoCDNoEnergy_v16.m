/**
 * 剑影江湖 v16.0 - 安全分离策略
 *
 * v15.1问题诊断：
 *   用户反馈：大号在训练场，用游戏自带[重置技能]充满怒气→大招能释放→点击大招后卡住
 *
 * 卡住原因分析(关键推理)：
 *   1. v15.1同时hook了 IsExSkillInCD(→强制返回NO) + TryTriggerExSkill(8参数hook)
 *   2. TryTriggerExSkill是帧同步确定性函数，在帧同步循环中被调用
 *      - hook中做vm_region_64/暴力搜索Frame等耗时操作 → 帧同步超时
 *      - 修改ExSkillData数据 → 客户端和服务端状态不一致 → 校验失败
 *   3. IsExSkillInCD强制返回NO → 客户端认为CD已过，但服务端ExSkillData.LastTriggerTime没清零
 *      → 帧同步校验不一致 → 回滚/卡死
 *   4. 结论：两个帧同步内部hook叠加导致卡住
 *
 * v16.0核心策略：
 *   [1] 忽略解锁: CheckSkillUnlock → true (已验证安全，UI层检查)
 *   [2] 大招可用: CanUseExSkill → true (使用次数检查，非帧同步关键)
 *   [3] 伤害上限: get_limitDamage → g_damageLimit (静态属性，安全)
 *   [4] 大招无CD+怒气: 分步实验!
 *       第一步：只hook IsExSkillInCD，但不强制返回NO
 *              而是修改ExSkillData.Data(怒气)为极大值 + LastTriggerTime清零
 *              然后调原函数让它自然返回NO(CD已过+怒气已满)
 *       如果IsExSkillInCD仍然不被调用(v14已证实)：
 *       第二步：hook TryTriggerExSkill，但做最轻量的操作——
 *              不做vm_region_64，不暴力搜索，只调get_ExSkillDatas()获取Offset
 *              用FrameBase.ResolveList(Ptr offset)直接得到QListInternal*
 *              从QListInternal获取ExSkillData数组，修改Data+LastTriggerTime
 *              然后调原函数(不修改返回值)
 *       关键：如果这是PVE训练场(无服务端校验)，帧同步不一致也不会卡住
 *             如果是PVP(有服务端校验)，则任何数据修改都会导致问题
 *
 * 帧同步安全等级：
 *   ✅ 安全(纯判断，不修改帧同步数据):
 *     - CheckSkillUnlock → true
 *     - CanUseExSkill → true
 *     - get_limitDamage → g_damageLimit
 *   ⚠️ 需验证(帧同步内部函数，但只修改数据不改返回值):
 *     - IsExSkillInCD → 修改ExSkillData让原函数返回NO
 *   ⚠️ 需验证(帧同步函数，轻量hook+修改数据):
 *     - TryTriggerExSkill → 修改ExSkillData后调原函数
 *   ❌ 致命(帧同步核心循环，任何hook都卡死):
 *     - CheckSkillAttackCanUse / CheckSkillIsReady
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

// QListInternal结构偏移
// QListInternal: _count(+0x10), _items(QBuffer)(+0x14)
// QBuffer: Length(+0x10), Stride(+0x14), Ptr(+0x18)
// Ptr: Offset(+0x10)
static const int QLI_COUNT = 0x10;
static const int QLI_ITEMS = 0x14;  // QBuffer starts here
static const int QB_LENGTH = 0x10;
static const int QB_STRIDE = 0x14;
static const int QB_PTR = 0x18;     // Ptr struct starts here
static const int PTR_OFFSET = 0x10;

// ============================================================
// Hook函数指针
// ============================================================

typedef BOOL (*BoolFunc3)(void*, int, int);  // 3参数函数
typedef BOOL (*BoolFunc8)(void*, uint64_t, void*, void*, void*, void*, void*, uint64_t);  // 8参数函数(TryTriggerExSkill)
typedef int  (*IntFunc1)(void*);
typedef int32_t (*GetExSkillDatasFunc)(void*);  // get_ExSkillDatas
typedef void* (*ResolveListFunc)(void*, int32_t);  // FrameBase.ResolveList(Ptr) → QListInternal*
typedef BOOL (*TryGetExSkillDataPointerFunc)(void*, void*, int32_t, void**);  // TryGetExSkillDataPointer(Frame, id, out ExSkillData*&)

static void *g_funcCheckSkillUnlock = NULL; static BoolFunc3 g_origCheckSkillUnlock = NULL; static BOOL g_skillUnlockHooked = NO;
static void *g_funcCanUseExSkill = NULL;    static BoolFunc3 g_origCanUseExSkill = NULL;    static BOOL g_canUseExSkillHooked = NO;
static void *g_funcTryTriggerExSkill = NULL; static BoolFunc8 g_origTryTriggerExSkill = NULL; static BOOL g_tryTriggerHooked = NO;
static void *g_funcLimitDmg = NULL;         static IntFunc1 g_origLimitDmg = NULL;          static BOOL g_limitHooked = NO;
static GetExSkillDatasFunc g_funcGetExSkillDatas = NULL;
static ResolveListFunc g_funcResolveList = NULL;
static TryGetExSkillDataPointerFunc g_funcTryGetExSkillDataPointer = NULL;

// ============================================================
// 辅助函数: 通过Frame.ResolveList获取ExSkillData数组
// ============================================================

/**
 * 使用FrameBase.ResolveList(Ptr offset)来获取QListInternal*
 * 然后从QListInternal中提取ExSkillData数组
 *
 * FrameBase.ResolveList签名: QListInternal* ResolveList(Ptr ptr)
 *   Ptr只有一个字段: Int32 Offset (+0x10)
 *   返回值: QListInternal* (在Frame的heap中)
 *
 * QListInternal结构:
 *   +0x10: _count (Int32)
 *   +0x14: _items (QBuffer)
 *     QBuffer:
 *       +0x10: Length (Int32)
 *       +0x14: Stride (Int32)
 *       +0x18: Ptr (只有一个Offset字段+0x10)
 *
 * ExSkillData数组地址 = heap_base + Ptr.Offset
 */
static void fillExSkillAngerViaAPI(void *f, void *character) {
    if (!g_funcGetExSkillDatas || !character) return;

    // Step 1: 获取ExSkillDatas的QListPtr (即Ptr.Offset)
    int32_t listOffset = g_funcGetExSkillDatas(character);

    static int apiLogCount = 0;
    if (apiLogCount < 20) {
        apiLogCount++;
        jlog(@"fillAnger: get_ExSkillDatas()=%d (0x%x)", listOffset, listOffset);
    }

    if (listOffset <= 0) {
        jlog(@"fillAnger: listOffset=%d invalid, skip", listOffset);
        return;
    }

    // Step 2: 用FrameBase.ResolveList(Ptr offset)获取QListInternal*
    if (!g_funcResolveList || !f) {
        jlog(@"fillAnger: ResolveList or Frame not available, skip");
        return;
    }

    void *qListInternal = g_funcResolveList(f, listOffset);
    if (!qListInternal) {
        jlog(@"fillAnger: ResolveList returned NULL for offset=%d", listOffset);
        return;
    }

    // Step 3: 从QListInternal读取count和QBuffer
    int32_t count = *(int32_t*)((uint8_t*)qListInternal + QLI_COUNT);
    if (count <= 0 || count > 20) {
        jlog(@"fillAnger: count=%d invalid", count);
        return;
    }

    // QBuffer在QListInternal+0x14处
    uint8_t *qbuf = (uint8_t*)qListInternal + QLI_ITEMS;
    int32_t length = *(int32_t*)(qbuf + QB_LENGTH);
    int32_t stride = *(int32_t*)(qbuf + QB_STRIDE);
    int32_t dataOffset = *(int32_t*)(qbuf + QB_PTR + PTR_OFFSET);

    if (apiLogCount <= 20) {
        jlog(@"fillAnger: QListInternal=%p count=%d len=%d stride=%d dataOff=%d",
             qListInternal, count, length, stride, dataOffset);
    }

    // Step 4: 解析ExSkillData数组
    // data_base + dataOffset → ExSkillData数组
    // 但data_base是什么？它是Frame的heap基地址
    // ResolveList返回的QListInternal已经在heap中了
    // QBuffer.Ptr.Offset是相对于heap的偏移
    //
    // 关键问题：我们不知道heap基地址
    // 但我们知道：ResolveList(Offset) = heap_base + Offset
    // 所以：heap_base = ResolveList(0) 或者 heap_base = qListInternal - listOffset
    // 更准确地说：QListInternal本身就在heap中
    // ExSkillData数组 = heap_base + dataOffset
    //
    // 用同样的方法：调用ResolveList(dataOffset)获取数组指针？
    // 不对，ResolveList返回的是QListInternal*，不是原始数据
    //
    // 让我换一种方法：用TryGetExSkillDataPointer API!
    // 它签名: Boolean TryGetExSkillDataPointer(Frame f, Int32 id, out ExSkillData*& p)
    // 这直接给我们ExSkillData指针!

    jlog(@"fillAnger: stride=0x%x (expected 0x%x), dataOff=%d", stride, ESD_SIZE, dataOffset);

    // 尝试通过TryGetExSkillDataPointer获取
    if (g_funcTryGetExSkillDataPointer && f) {
        // 我们需要ExSkillData的id，先用QListInternal中的数据找
        // 或者直接用id=0来遍历
        void *exSkillDataPtr = NULL;
        // TryGetExSkillDataPointer(Frame f, Int32 id, out ExSkillData*& p)
        // ARM64: x0=self(CharacterFiled*), x1=Frame, x2=id, x3=out ptr
        // 但这是实例方法，self=CharacterFiled*
        // 签名: public Boolean TryGetExSkillDataPointer(Frame f, Int32 id, out ExSkillData*& p)
        // 所以: self=x0=CharacterFiled*, x1=Frame, x2=id, x3=out ExSkillData**
        BOOL result = g_funcTryGetExSkillDataPointer(character, f, 0, &exSkillDataPtr);
        jlog(@"fillAnger: TryGetExSkillDataPointer(0)=%d ptr=%p", result, exSkillDataPtr);

        if (result && exSkillDataPtr) {
            // 成功获取第一个ExSkillData指针!
            // 验证数据合理性
            int16_t lv = *(int16_t*)((uint8_t*)exSkillDataPtr + ESD_LV);
            int32_t id = *(int32_t*)((uint8_t*)exSkillDataPtr + ESD_ID);
            uint64_t data = *(uint64_t*)((uint8_t*)exSkillDataPtr + ESD_DATA);
            jlog(@"fillAnger: ExSkillData[0] id=%d lv=%d data=0x%llx", id, lv, data);

            // 修改所有ExSkillData
            for (int i = 0; i < count && i < 10; i++) {
                uint8_t *p = (uint8_t*)exSkillDataPtr + i * ESD_SIZE;

                // 安全检查
                int32_t curId = *(int32_t*)(p + ESD_ID);
                if (curId == 0 && i > 0) break; // 空数据

                // 设置怒气值为极大值: FP(10000) = 10000 << 16
                *(uint64_t*)(p + ESD_DATA) = (uint64_t)10000 << 16;
                // 清除CD: LastTriggerTime=0
                *(uint64_t*)(p + ESD_LASTTRIGGERTIME) = 0;
                // 等级设为30
                *(int16_t*)(p + ESD_LV) = 30;

                jlog(@"fillAnger[%d]: id=%d → anger=max cd=0 lv=30", i, curId);
            }
            return;
        }
    }

    // Fallback: 直接用QListInternal中的数据
    // heap_base的估算: QListInternal的地址 = heap_base + listOffset
    // 所以 heap_base ≈ (uint8_t*)qListInternal - listOffset
    // ExSkillData数组 ≈ heap_base + dataOffset
    if (dataOffset > 0) {
        uint8_t *heapBase = (uint8_t*)qListInternal - listOffset;
        uint8_t *exDataArray = heapBase + dataOffset;

        // 验证
        int32_t firstId = *(int32_t*)(exDataArray + ESD_ID);
        int16_t firstLv = *(int16_t*)(exDataArray + ESD_LV);
        jlog(@"fillAnger fallback: heapBase=%p exData=%p id=%d lv=%d",
             heapBase, exDataArray, firstId, firstLv);

        if (firstId > 0 && firstId < 100000 && stride == ESD_SIZE) {
            for (int i = 0; i < count && i < 10; i++) {
                uint8_t *p = exDataArray + i * ESD_SIZE;
                *(uint64_t*)(p + ESD_DATA) = (uint64_t)10000 << 16;
                *(uint64_t*)(p + ESD_LASTTRIGGERTIME) = 0;
                *(int16_t*)(p + ESD_LV) = 30;
            }
            jlog(@"fillAnger fallback: modified %d entries", count);
        }
    }
}

// ============================================================
// Hook函数实现
// ============================================================

/**
 * [1] 忽略解锁: CheckSkillUnlock → true
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
 */
static int g_canUseLogCount = 0;
static BOOL hookCanUseExSkill(void *self, int a1, int a2) {
    if (g_exSkillAvail) {
        if (g_canUseLogCount < 5) {
            g_canUseLogCount++;
            jlog(@"CanUseExSkill[%d]: a1=%d a2=%d", g_canUseLogCount, a1, a2);
        }
        return YES;
    }
    if (g_origCanUseExSkill) return g_origCanUseExSkill(self, a1, a2);
    return YES;
}

/**
 * [4] 大招无CD+怒气: TryTriggerExSkill hook (轻量版)
 *
 * v16.0关键改进:
 *   - 不做vm_region_64等耗时系统调用
 *   - 不暴力搜索Frame字段
 *   - 使用ResolveList API直接获取QListInternal*
 *   - 修改ExSkillData后调原函数(不修改返回值)
 *   - 整个hook耗时控制在微秒级
 *
 * 签名: static Boolean TryTriggerExSkill(
 *   Frame f, x0; ExSkillTriggerType type, x1(UInt64);
 *   EntityRef trigger, x2; EntityRef fuse, x3;
 *   List<EntityRef> targets, x4;
 *   CharacterFiled* character, x5; ExSkillsAsset asset, x6; UInt64 triggerData, x7
 * );
 */
static int g_tryTriggerLogCount = 0;

static BOOL hookTryTriggerExSkill(void *f, uint64_t type, void *trigger, void *fuse,
                                   void *targets, void *character, void *asset, uint64_t triggerData) {
    // 轻量日志
    if (g_tryTriggerLogCount < 30) {
        g_tryTriggerLogCount++;
        jlog(@"TryTrigger[%d] type=%llu f=%p char=%p", g_tryTriggerLogCount, type, f, character);
    }

    // 修改ExSkillData(仅在开启时)
    if (g_exSkillNoCD && character && f) {
        fillExSkillAngerViaAPI(f, character);
    }

    // 调原函数，不修改返回值
    if (g_origTryTriggerExSkill) {
        return g_origTryTriggerExSkill(f, type, trigger, fuse, targets, character, asset, triggerData);
    }
    return NO;
}

/** [3] 伤害上限: get_limitDamage → g_damageLimit */
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
    jlog(@"=== v16.0 IL2CPP Runtime Search ===");

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

                if (strcmp(n, "CheckSkillUnlock") == 0 && !g_funcCheckSkillUnlock) {
                    jlog(@"FOUND %s.CheckSkillUnlock params=%u addr=%p [1.忽略解锁]", cn ?: "?", pc, funcAddr);
                    g_funcCheckSkillUnlock = funcAddr; found++;
                }
                else if (strcmp(n, "CanUseExSkill") == 0 && !g_funcCanUseExSkill) {
                    jlog(@"FOUND %s.CanUseExSkill params=%u addr=%p [2.大招可用]", cn ?: "?", pc, funcAddr);
                    g_funcCanUseExSkill = funcAddr; found++;
                }
                else if (strcmp(n, "TryTriggerExSkill") == 0 && !g_funcTryTriggerExSkill) {
                    jlog(@"FOUND %s.TryTriggerExSkill params=%u addr=%p [4.大招无CD]", cn ?: "?", pc, funcAddr);
                    g_funcTryTriggerExSkill = funcAddr; found++;
                }
                else if (strcmp(n, "get_limitDamage") == 0 && !g_funcLimitDmg) {
                    jlog(@"FOUND %s.get_limitDamage params=%u addr=%p [3.伤害上限]", cn ?: "?", pc, funcAddr);
                    g_funcLimitDmg = funcAddr; found++;
                }
                else if (strcmp(n, "get_ExSkillDatas") == 0 && !g_funcGetExSkillDatas) {
                    jlog(@"FOUND %s.get_ExSkillDatas params=%u addr=%p [helper]", cn ?: "?", pc, funcAddr);
                    g_funcGetExSkillDatas = (GetExSkillDatasFunc)funcAddr; found++;
                }
                else if (strcmp(n, "TryGetExSkillDataPointer") == 0 && !g_funcTryGetExSkillDataPointer) {
                    jlog(@"FOUND %s.TryGetExSkillDataPointer params=%u addr=%p [helper]", cn ?: "?", pc, funcAddr);
                    g_funcTryGetExSkillDataPointer = (TryGetExSkillDataPointerFunc)funcAddr; found++;
                }
                else if (strcmp(n, "ResolveList") == 0 && !g_funcResolveList && cn && strcmp(cn, "FrameBase") == 0) {
                    jlog(@"FOUND %s.ResolveList params=%u addr=%p [helper]", cn ?: "?", pc, funcAddr);
                    g_funcResolveList = (ResolveListFunc)funcAddr; found++;
                }
            }
        }
    }

    jlog(@"Scanned %d methods, found %d targets", totalMethods, found);
    jlog(@"[1]Unlock=%p [2]CanUse=%p [3]LimitDmg=%p [4]TryTrigger=%p",
         g_funcCheckSkillUnlock, g_funcCanUseExSkill, g_funcLimitDmg, g_funcTryTriggerExSkill);
    jlog(@"[helper]GetExData=%p TryGetPtr=%p ResolveList=%p",
         (void*)g_funcGetExSkillDatas, (void*)g_funcTryGetExSkillDataPointer, (void*)g_funcResolveList);
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

    // 只安装伤害上限(默认开启)，其余惰性安装
    hookOneFunc(g_funcLimitDmg, hookLimitDmg, (void**)&g_origLimitDmg, &g_limitHooked, "3.伤害上限");

    jlog(@"applyAllHooks done hooked: Unlock=%d ExAvail=%d TryTrigger=%d Limit=%d",
         g_skillUnlockHooked, g_canUseExSkillHooked, g_tryTriggerHooked, g_limitHooked);
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
    if (g_exSkillNoCD && !g_tryTriggerHooked) {
        findIL2CPP();
        // v16.0: 只hook TryTriggerExSkill，不hook IsExSkillInCD
        // IsExSkillInCD强制返回NO是卡住的主因
        hookOneFunc(g_funcTryTriggerExSkill, hookTryTriggerExSkill, (void**)&g_origTryTriggerExSkill, &g_tryTriggerHooked, "4.大招无CD");
    }
    refreshButtons(); jlog(@"Toggle 大招无CD: %d hooked=%d", g_exSkillNoCD, g_tryTriggerHooked);
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
    title.text=@"\u5251\u5f71\u6c5f\u6e56 v16.0"; title.textColor=[UIColor cyanColor];
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

    jlog(@"========== JYJH v16.0 (轻量TryTrigger hook + ResolveList API) ==========");
    jlog(@"iOS %@", [[UIDevice currentDevice] systemVersion]);
    jlog(@"Bundle %@", [[NSBundle mainBundle] bundleIdentifier]);
    jlog(@"v16.0变更:");
    jlog(@"  去掉IsExSkillInCD强制返回NO(这是v15卡住的主因)");
    jlog(@"  TryTriggerExSkill hook改为轻量版: 用ResolveList/TryGetExSkillDataPointer API");
    jlog(@"  不做vm_region/暴力搜索等耗时操作");
    jlog(@"  修改ExSkillData后调原函数(不改返回值)");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(5.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        jlog(@"5s delay done, applying hooks...");
        applyAllHooks();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            setupUI();
        });
    });
}
