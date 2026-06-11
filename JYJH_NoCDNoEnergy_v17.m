/**
 * 剑影江湖 v17.0 - 根本性策略变更：走游戏合法输入通道
 *
 * v16日志分析：
 *   - 所有7个API都找到了 ✅
 *   - 所有4个hook都DobbyHook成功 ✅
 *   - CheckSkillUnlock正常被调用 ✅
 *   - CanUseExSkill正常被hook ✅
 *   - TryTriggerExSkill hook成功 ✅
 *   - 但TryTriggerExSkill没被调用！（日志无TryTrigger输出）
 *   - 用户反馈：大招还是没效果，关闭忽略解锁后点大招卡住
 *
 * 根因分析（关键推理）：
 *   TryTriggerExSkill在v15.1中被调用过(type=1024)，
 *   但v16中没被调用 → 差异在于：v15.1中IsExSkillInCD也hook了
 *
 *   实际大招触发流程：
 *   1. 玩家点大招按钮 → 发送输入到帧同步
 *   2. 帧同步处理输入 → 调用CheckSkillAttackCanUse/CheckSkillIsReady
 *      (这两个是帧同步核心函数，任何hook都卡死！)
 *   3. 如果检查通过 → 调用TryTriggerExSkill
 *   4. TryTriggerExSkill内部检查怒气 → ExSkillData.Data是否足够
 *   5. 怒气不够 → TryTriggerExSkill返回false（或直接不走大招路径）
 *      → 走普通技能路径 → 不触发大招
 *   6. 怒气够 → IsExSkillInCD检查 → 触发大招
 *
 *   这就是为什么：
 *   - 忽略解锁有效(CheckSkillUnlock不在关键路径上)
 *   - 大招可用无效(CanUseExSkill只管使用次数，不管怒气)
 *   - 大招无CD无效(TryTriggerExSkill根本没被调用)
 *   - 关闭忽略解锁点大招卡住(CheckSkillIsReady在关键路径上)
 *
 *   帧同步验证的关键路径：
 *   CheckSkillAttackCanUse/CheckSkillIsReady → 决定技能是否可用
 *   这两个函数检查：等级解锁 + 怒气 + CD + 状态
 *   如果我们hook CheckSkillUnlock=true但怒气不够，
 *   CheckSkillIsReady内部检查ExSkillData.Data → 怒气不足 → 返回false
 *   → 技能不可用 → 不触发TryTriggerExSkill
 *
 * v17核心策略 - 彻底换思路：
 *   不再试图在帧同步内部修改数据或hook判断函数！
 *   改为：让帧同步的怒气自动增长！
 *
 *   方法：hook TriggerExSkillOrAdd！
 *   签名: static Boolean TriggerExSkillOrAdd(
 *     Frame f, EntityRef trigger, CharacterFiled* characterField,
 *     FP now, ExSkillInfo info, ExSkillsAsset asset, Int16 lv)
 *   这是7参数函数，当怒气不够时被调用（名字暗示"触发大招或增加怒气"）
 *   - 如果怒气足够 → 触发大招
 *   - 如果怒气不够 → 增加怒气
 *   hook此函数：强制触发大招（返回true）而不是增加怒气
 *
 *   更好的方法：直接在TryTriggerExSkill的hook中修改ExSkillData.Data
 *   让怒气看起来是满的，然后调原函数
 *   但v16的问题是TryTriggerExSkill没被调用...
 *
 *   最终方案：同时hook TryTriggerExSkill + 修改ExSkillData
 *   关键改变：在TryTriggerExSkill hook中用get_ExSkillDatas() + ResolveList
 *   正确解析QListPtr，直接修改ExSkillData.Data为极大值
 *   然后调原函数让它走正常的大招触发路径
 *
 *   但如果TryTriggerExSkill根本不被调用，说明问题在上游：
 *   CheckSkillIsReady检查怒气不够，直接返回false，不走大招路径
 *   → 这就解释了为什么大招没效果
 *
 *   真正的解决方案：
 *   1. CheckSkillUnlock → true (解锁等级限制，已验证安全)
 *   2. 在每帧更新时修改ExSkillData.Data(怒气)为极大值
 *      这样当CheckSkillIsReady检查时，怒气始终是满的
 *   3. 但我们没有一个安全的"每帧更新"hook点...
 *
 *   v17策略B（实用方案）：
 *   既然帧同步环境无法安全修改数据，那就走UI层：
 *   - 搜索并hook UI层的大招按钮可用性判断
 *   - 让UI显示大招可用（即使帧同步认为不可用）
 *   - 用户点击后，输入发送到帧同步，帧同步走正常流程
 *   - 如果帧同步中怒气不够，大招仍然无法释放
 *   → 所以这条路也走不通
 *
 *   v17策略C（最终方案）：
 *   既然问题核心是怒气不够，而怒气是ExSkillData.Data（帧同步数据），
 *   任何在帧同步内的修改都会导致校验失败。
 *   但！训练场/PVE模式可能没有严格的服务端校验！
 *
 *   方案：在TryTriggerExSkill hook中修改ExSkillData.Data
 *   但这次确保hook确实被调用！
 *   v16中TryTriggerExSkill没被调用的原因：
 *   用户先开了忽略解锁+大招可用+大招无CD，然后又全部关掉了！
 *   日志第50-52行：Toggle all OFF！
 *   第二次进入战斗时所有hook都关了，自然没有TryTrigger输出
 *
 *   v17方案：
 *   1. 保留忽略解锁(安全)
 *   2. 保留伤害上限(安全)
 *   3. 大招可用(CanUseExSkill→true，使用次数检查)
 *   4. 大招无CD：改为直接修改ExSkillData.Data
 *      - 使用TryGetExSkillDataPointer获取ExSkillData指针
 *      - 修改Data为极大值 + LastTriggerTime清零
 *      - 这需要在TryTriggerExSkill被调用时才能执行
 *      - 但TryTriggerExSkill只在怒气够的时候才被调用...
 *      → 死循环！
 *
 *   v17最终方案：
 *   破局关键：修改怒气增长速度！
 *   帧同步中每次攻击命中都会增加ExSkillData.Data
 *   如果我们让每次增加的量变大(比如100倍)，怒气就会快速充满
 *   这样不需要修改ExSkillData的值，只需要修改增量
 *   → 但增量是在帧同步代码中硬编码的，无法从外部修改
 *
 *   算了，回到最简单直接的方案：
 *   hook TriggerExSkillOrAdd → 强制返回true（触发大招）
 *   这个函数在怒气不够时被调用，本来会增加怒气
 *   我们强制让它触发大招而不是增加怒气
 *   地址: 0x30baaac, 7参数
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
// 日志
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

static BOOL g_ignoreUnlock = NO;
static BOOL g_exSkillAvail = NO;
static BOOL g_exSkillNoCD = NO;
static int g_damageLimit = 100;

// ============================================================
// Hook函数指针
// ============================================================

typedef BOOL (*BoolFunc3)(void*, int, int);
typedef int  (*IntFunc1)(void*);

// TryTriggerExSkill: 8参数 (Frame*, UInt64, void*, void*, void*, void*, void*, UInt64)
typedef BOOL (*BoolFunc8)(void*, uint64_t, void*, void*, void*, void*, void*, uint64_t);

// TriggerExSkillOrAdd: 7参数 (Frame*, EntityRef(trigger), CharacterFiled*, FP(now), ExSkillInfo, ExSkillsAsset, Int16 lv)
// ARM64: x0=Frame*, x1=trigger(EntityRef=8字节值类型), x2=CharacterFiled*, x3=now(FP=8字节), x4=info(ExSkillInfo=class ref), x5=asset(ExSkillsAsset=class ref), x6=lv(Int16)
typedef BOOL (*BoolFunc7)(void*, uint64_t, void*, uint64_t, void*, void*, int);

// get_ExSkillDatas: (CharacterFiled*) -> int32_t (QListPtr.Ptr.Offset)
typedef int32_t (*GetExSkillDatasFunc)(void*);

// ResolveList: (FrameBase*, int32_t) -> void* (QListInternal*)
typedef void* (*ResolveListFunc)(void*, int32_t);

// TryGetExSkillDataPointer: (CharacterFiled*, Frame*, int32_t id, void** outPtr) -> BOOL
typedef BOOL (*TryGetExSkillDataPointerFunc)(void*, void*, int32_t, void**);

static void *g_funcCheckSkillUnlock = NULL; static BoolFunc3 g_origCheckSkillUnlock = NULL; static BOOL g_skillUnlockHooked = NO;
static void *g_funcCanUseExSkill = NULL;    static BoolFunc3 g_origCanUseExSkill = NULL;    static BOOL g_canUseExSkillHooked = NO;
static void *g_funcTryTriggerExSkill = NULL; static BoolFunc8 g_origTryTriggerExSkill = NULL; static BOOL g_tryTriggerHooked = NO;
static void *g_funcTriggerExSkillOrAdd = NULL; static BoolFunc7 g_origTriggerExSkillOrAdd = NULL; static BOOL g_triggerOrAddHooked = NO;
static void *g_funcLimitDmg = NULL;         static IntFunc1 g_origLimitDmg = NULL;          static BOOL g_limitHooked = NO;

static GetExSkillDatasFunc g_funcGetExSkillDatas = NULL;
static ResolveListFunc g_funcResolveList = NULL;
static TryGetExSkillDataPointerFunc g_funcTryGetExSkillDataPointer = NULL;

// ============================================================
// ExSkillData偏移
// ============================================================

static const int ESD_LV = 0x00;
static const int ESD_ID = 0x04;
static const int ESD_DATA = 0x08;
static const int ESD_LASTTRIGGERTIME = 0x10;
static const int ESD_SKILLS = 0x18;
static const int ESD_SIZE = 0x20;

// ============================================================
// 辅助：修改ExSkillData怒气
// ============================================================

static void fillExSkillAnger(void *f, void *character) {
    if (!g_funcGetExSkillDatas || !character) return;

    int32_t listOffset = g_funcGetExSkillDatas(character);

    static int apiLogCount = 0;
    if (apiLogCount < 30) {
        apiLogCount++;
        jlog(@"fillAnger[%d]: get_ExSkillDatas()=%d (0x%x) f=%p char=%p",
             apiLogCount, listOffset, listOffset, f, character);
    }

    if (listOffset <= 0) return;

    // 用ResolveList获取QListInternal
    if (!g_funcResolveList || !f) return;

    void *qListInternal = g_funcResolveList(f, listOffset);
    if (!qListInternal) return;

    // QListInternal._count at +0x10
    int32_t count = *(int32_t*)((uint8_t*)qListInternal + 0x10);
    if (count <= 0 || count > 20) return;

    // 用TryGetExSkillDataPointer获取第一个ExSkillData
    if (g_funcTryGetExSkillDataPointer && f) {
        void *exSkillDataPtr = NULL;
        BOOL result = g_funcTryGetExSkillDataPointer(character, f, 0, &exSkillDataPtr);

        if (result && exSkillDataPtr) {
            int16_t lv = *(int16_t*)((uint8_t*)exSkillDataPtr + ESD_LV);
            int32_t id = *(int32_t*)((uint8_t*)exSkillDataPtr + ESD_ID);
            uint64_t data = *(uint64_t*)((uint8_t*)exSkillDataPtr + ESD_DATA);
            jlog(@"fillAnger: TryGetPtr OK id=%d lv=%d data=0x%llx", id, lv, data);

            for (int i = 0; i < count && i < 10; i++) {
                uint8_t *p = (uint8_t*)exSkillDataPtr + i * ESD_SIZE;
                int32_t curId = *(int32_t*)(p + ESD_ID);
                if (curId == 0 && i > 0) break;

                *(uint64_t*)(p + ESD_DATA) = (uint64_t)10000 << 16;
                *(uint64_t*)(p + ESD_LASTTRIGGERTIME) = 0;
                *(int16_t*)(p + ESD_LV) = 30;

                jlog(@"fillAnger[%d]: id=%d → anger=max cd=0 lv=30", i, curId);
            }
            return;
        }
    }

    // Fallback: 通过heap_base计算
    int32_t stride = *(int32_t*)((uint8_t*)qListInternal + 0x14 + 0x14);
    int32_t dataOffset = *(int32_t*)((uint8_t*)qListInternal + 0x14 + 0x18 + 0x10);

    jlog(@"fillAnger fallback: count=%d stride=0x%x dataOff=%d", count, stride, dataOffset);

    if (dataOffset > 0 && stride == ESD_SIZE) {
        uint8_t *heapBase = (uint8_t*)qListInternal - listOffset;
        uint8_t *exDataArray = heapBase + dataOffset;

        int32_t firstId = *(int32_t*)(exDataArray + ESD_ID);
        if (firstId > 0 && firstId < 100000) {
            for (int i = 0; i < count && i < 10; i++) {
                uint8_t *p = exDataArray + i * ESD_SIZE;
                *(uint64_t*)(p + ESD_DATA) = (uint64_t)10000 << 16;
                *(uint64_t*)(p + ESD_LASTTRIGGERTIME) = 0;
                *(int16_t*)(p + ESD_LV) = 30;
            }
            jlog(@"fillAnger fallback OK: modified %d entries", count);
        }
    }
}

// ============================================================
// Hook函数实现
// ============================================================

static int g_unlockLogCount = 0;
static BOOL hookCheckSkillUnlock(void *self, int a1, int a2) {
    if (g_ignoreUnlock) {
        if (g_unlockLogCount < 10) {
            g_unlockLogCount++;
            jlog(@"Unlock[%d]: stateType=%d", g_unlockLogCount, a2);
        }
        return YES;
    }
    if (g_origCheckSkillUnlock) return g_origCheckSkillUnlock(self, a1, a2);
    return YES;
}

static int g_canUseLogCount = 0;
static BOOL hookCanUseExSkill(void *self, int a1, int a2) {
    if (g_exSkillAvail) {
        if (g_canUseLogCount < 10) {
            g_canUseLogCount++;
            jlog(@"CanUseExSkill[%d]: a1=%d a2=%d → YES", g_canUseLogCount, a1, a2);
        }
        return YES;
    }
    if (g_origCanUseExSkill) return g_origCanUseExSkill(self, a1, a2);
    return YES;
}

/**
 * [4a] TryTriggerExSkill hook - 修改ExSkillData后调原函数
 * 8参数: Frame*, UInt64, void*, void*, void*, void*, void*, UInt64
 */
static int g_tryTriggerLogCount = 0;
static BOOL hookTryTriggerExSkill(void *f, uint64_t type, void *trigger, void *fuse,
                                   void *targets, void *character, void *asset, uint64_t triggerData) {
    if (g_tryTriggerLogCount < 30) {
        g_tryTriggerLogCount++;
        jlog(@"TryTrigger[%d] type=%llu f=%p char=%p noCD=%d",
             g_tryTriggerLogCount, type, f, character, g_exSkillNoCD);
    }

    if (g_exSkillNoCD && character && f) {
        fillExSkillAnger(f, character);
    }

    if (g_origTryTriggerExSkill) {
        return g_origTryTriggerExSkill(f, type, trigger, fuse, targets, character, asset, triggerData);
    }
    return NO;
}

/**
 * [4b] TriggerExSkillOrAdd hook - 关键！
 * 签名: static Boolean TriggerExSkillOrAdd(
 *   Frame f, EntityRef trigger, CharacterFiled* characterField,
 *   FP now, ExSkillInfo info, ExSkillsAsset asset, Int16 lv)
 * ARM64: x0=Frame*, x1=trigger(EntityRef=8字节), x2=CharacterFiled*,
 *        x3=now(FP=8字节), x4=info, x5=asset, x6=lv
 *
 * 这个函数在怒气不够时被调用：
 * - 原逻辑：怒气够→触发大招返回true，怒气不够→增加怒气返回false
 * - hook后：先fillExSkillAnger(填满怒气)，再调原函数
 *   原函数看到怒气已满→触发大招→返回true
 */
static int g_orAddLogCount = 0;
static BOOL hookTriggerExSkillOrAdd(void *f, uint64_t trigger, void *character,
                                     uint64_t now, void *info, void *asset, int lv) {
    if (g_orAddLogCount < 30) {
        g_orAddLogCount++;
        jlog(@"OrAdd[%d] f=%p char=%p now=0x%llx lv=%d noCD=%d",
             g_orAddLogCount, f, character, now, lv, g_exSkillNoCD);
    }

    if (g_exSkillNoCD && character && f) {
        // 先填满怒气
        fillExSkillAnger(f, character);

        // 调原函数 - 现在怒气已满，原函数应该触发大招
        if (g_origTriggerExSkillOrAdd) {
            BOOL result = g_origTriggerExSkillOrAdd(f, trigger, character, now, info, asset, lv);
            jlog(@"OrAdd[%d]: result=%d (after fill anger)", g_orAddLogCount, result);
            return result;
        }
    }

    if (g_origTriggerExSkillOrAdd) {
        return g_origTriggerExSkillOrAdd(f, trigger, character, now, info, asset, lv);
    }
    return NO;
}

static int hookLimitDmg(void *self) {
    return g_damageLimit;
}

// ============================================================
// IL2CPP运行时
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

static void findIL2CPP(void) {
    jlog(@"=== v17.0 IL2CPP Runtime Search ===");

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
                    jlog(@"FOUND %s.TryTriggerExSkill params=%u addr=%p [4a.大招触发]", cn ?: "?", pc, funcAddr);
                    g_funcTryTriggerExSkill = funcAddr; found++;
                }
                else if (strcmp(n, "TriggerExSkillOrAdd") == 0 && !g_funcTriggerExSkillOrAdd) {
                    jlog(@"FOUND %s.TriggerExSkillOrAdd params=%u addr=%p [4b.触发或加怒气]", cn ?: "?", pc, funcAddr);
                    g_funcTriggerExSkillOrAdd = funcAddr; found++;
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
    jlog(@"[1]Unlock=%p [2]CanUse=%p [3]LimitDmg=%p [4a]TryTrigger=%p [4b]OrAdd=%p",
         g_funcCheckSkillUnlock, g_funcCanUseExSkill, g_funcLimitDmg, g_funcTryTriggerExSkill, g_funcTriggerExSkillOrAdd);
    jlog(@"[helper]GetExData=%p TryGetPtr=%p ResolveList=%p",
         (void*)g_funcGetExSkillDatas, (void*)g_funcTryGetExSkillDataPointer, (void*)g_funcResolveList);
}

// ============================================================
// Dobby Hook
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
    hookOneFunc(g_funcLimitDmg, hookLimitDmg, (void**)&g_origLimitDmg, &g_limitHooked, "3.伤害上限");
    jlog(@"applyAllHooks done: Unlock=%d CanUse=%d TryTrigger=%d OrAdd=%d Limit=%d",
         g_skillUnlockHooked, g_canUseExSkillHooked, g_tryTriggerHooked, g_triggerOrAddHooked, g_limitHooked);
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
        // hook TryTriggerExSkill (怒气满时被调用)
        if (!g_tryTriggerHooked) {
            hookOneFunc(g_funcTryTriggerExSkill, hookTryTriggerExSkill, (void**)&g_origTryTriggerExSkill, &g_tryTriggerHooked, "4a.TryTrigger");
        }
        // hook TriggerExSkillOrAdd (怒气不够时被调用 - 关键！)
        if (!g_triggerOrAddHooked) {
            hookOneFunc(g_funcTriggerExSkillOrAdd, hookTriggerExSkillOrAdd, (void**)&g_origTriggerExSkillOrAdd, &g_triggerOrAddHooked, "4b.TriggerOrAdd");
        }
    }
    refreshButtons(); jlog(@"Toggle 大招无CD: %d hooked: TryTrigger=%d OrAdd=%d",
                           g_exSkillNoCD, g_tryTriggerHooked, g_triggerOrAddHooked);
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
    title.text=@"\u5251\u5f71\u6c5f\u6e56 v17.0"; title.textColor=[UIColor cyanColor];
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

    jlog(@"========== JYJH v17.0 (TriggerExSkillOrAdd策略) ==========");
    jlog(@"iOS %@", [[UIDevice currentDevice] systemVersion]);
    jlog(@"Bundle %@", [[NSBundle mainBundle] bundleIdentifier]);
    jlog(@"v17.0核心变更:");
    jlog(@"  新增hook TriggerExSkillOrAdd(怒气不够时被调用)");
    jlog(@"  在hook中先fillExSkillAnger填满怒气，再调原函数");
    jlog(@"  原函数看到怒气已满→触发大招而非增加怒气");
    jlog(@"  保留: TryTriggerExSkill hook(怒气满时被调用)");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(5.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        jlog(@"5s delay done, applying hooks...");
        applyAllHooks();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            setupUI();
        });
    });
}
