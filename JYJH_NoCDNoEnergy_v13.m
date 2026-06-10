/**
 * 剑影江湖 v13.0 - 数据修改策略
 *
 * v12.7的3个卡死问题根因分析:
 *   1. 低级号普通技能卡死: CheckSkillIsReady返回true但服务端验证失败(帧同步不一致)
 *   2. 大招等级不够: CheckSkillUnlock只是解锁检查, 大招等级在ExSkillData.lv中
 *   3. 大号无能量卡死: CheckSkillIsReady返回true但能量是帧同步状态
 *
 * v13.0核心策略转变: 不再强制返回true/false!
 *   而是**修改底层数据让原函数自己返回正确值**
 *
 * 具体方案:
 *   [1] 无CD: CheckSkillAttackCanUse hook中, 清除SkillStateData.CoolDown=0
 *       让原函数判断CD已好 → 自己返回true
 *   [2] 无能量: CheckSkillIsReady hook中, 清除SkillStateData.CoolDown=0 + Count恢复
 *       让原函数判断能量已满 → 自己返回true
 *   [3] 忽略解锁: CheckSkillUnlock 返回true (解锁是UI层检查, 不影响帧同步)
 *   [4] 大招可用: CanUseExSkill 返回true (使用次数检查, 不影响帧同步)
 *   [5] 大招无CD+怒气: IsExSkillInCD中修改ExSkillData:
 *       - Data(0x18) = FP极大值 (怒气满)
 *       - lv(0x10) = 30 (等级足够)
 *       - LastTriggerTime(0x20) = 0 (CD已过)
 *       然后返回NO(不在CD), 让原函数认为大招可用
 *   [6] 伤害上限: get_limitDamage 直接返回
 *
 * 数据结构参考 (dump.cs):
 *   SkillStateData: CoolDown(FP)=0x18, Count(Int16)=0x14, CountMax(Int16)=0x16
 *   CharacterSkillInfo: Skill1=0x40, Skill2=0x50, ..., 每个SkillStateData占0x10字节
 *   ExSkillData: lv(Int16)=0x10, id(Int32)=0x14, Data(FP)=0x18, LastTriggerTime(FP)=0x20, skills(UInt64)=0x28
 *   CharacterFiled: SkillInfo=0x200, AttributeAdd=0x170
 *   CharacterAttributeAdditional: SkillLvListPtr=0x14
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

static BOOL g_noCD = NO;           // 无CD (默认关, 需要用户手动开)
static BOOL g_noEnergy = NO;       // 无能量 (默认关)
static BOOL g_ignoreUnlock = NO;   // 忽略解锁 (默认关)
static BOOL g_exSkillAvail = NO;   // 大招可用 (默认关)
static BOOL g_exSkillNoCD = NO;    // 大招无CD+怒气 (默认关)
static int g_damageLimit = 100;    // 伤害上限

// CharacterStateType枚举值 (dump.cs确认)
// Skill1=14, Skill2=15, Skill3=16, Skill4=17, Skill5=18, Skill6=19
static const int SKILL1 = 14;
static const int SKILL5 = 18;
static const int SKILL6 = 19;

// ============================================================
// 数据结构偏移量
// ============================================================

// CharacterFiled偏移
static const int CF_SKILLINFO = 0x200;   // CharacterSkillInfo在CharacterFiled中的偏移

// CharacterSkillInfo偏移
// SkillStateData各技能偏移 (每个SkillStateData占0x10字节)
// Skill1=0x40, Skill2=0x50, Skill3=0x60, Skill4=0x70, Skill5=0x80, Skill6=0x90
static const int SKILL_OFFSETS[] = {0x40, 0x50, 0x60, 0x70, 0x80, 0x90};
// stateType 14→index 0, 15→1, 16→2, 17→3, 18→4, 19→5
static const int SKILL_INDEX_OFFSET = 14; // stateType - SKILL_INDEX_OFFSET = array index

// SkillStateData字段偏移 (相对于嵌入父结构时的起始位置, 不含0x10的值类型header)
// dump.cs原始偏移: CanNextSequence=0x10, CurSequence=0x11, SkillHitEnemy=0x12,
//   UsedTimes=0x13, Count=0x14, CountMax=0x16, CoolDown=0x18
// 作为嵌入字段时, 实际数据偏移 = 原始偏移 - 0x10
static const int SSD_USED_TIMES = 0x03;  // UsedTimes (Byte) 相对偏移3
static const int SSD_COUNT = 0x04;       // Count (Int16) 相对偏移4
static const int SSD_COUNTMAX = 0x06;    // CountMax (Int16) 相对偏移6
static const int SSD_COOLDOWN = 0x08;    // CoolDown (FP, 8字节) 相对偏移8

// ExSkillData字段偏移 (相对于指针指向的内存起始位置, 不含值类型header)
// dump.cs原始偏移: lv=0x10, id=0x14, Data=0x18, LastTriggerTime=0x20, skills=0x28
// 值类型在QListPtr连续内存中不含0x10的header, 实际偏移 = 原始偏移 - 0x10
// 注意: 这和v12.7用的偏移不同! v12.7用了错误的偏移(含header)导致大招不生效
static const int ESD_LV = 0x00;          // lv (Int16) 实际偏移=0x10-0x10=0x00
static const int ESD_ID = 0x04;          // id (Int32) 实际偏移=0x14-0x10=0x04
static const int ESD_DATA = 0x08;        // Data (FP, 8字节) = 怒气值 实际偏移=0x18-0x10=0x08
static const int ESD_LASTTRIGGERTIME = 0x10; // LastTriggerTime (FP, 8字节) 实际偏移=0x20-0x10=0x10
static const int ESD_SKILLS = 0x18;      // skills (UInt64) 实际偏移=0x28-0x10=0x18

// ============================================================
// Hook函数指针
// ============================================================

typedef BOOL (*BoolFunc4)(void*, int, int, int);
typedef int  (*IntFunc1)(void*);

static void *g_funcCanUse = NULL;          static BoolFunc4 g_origCanUse = NULL;          static BOOL g_cdHooked = NO;
static void *g_funcIsReady = NULL;         static BoolFunc4 g_origIsReady = NULL;         static BOOL g_energyHooked = NO;
static void *g_funcCheckSkillUnlock = NULL; static BoolFunc4 g_origCheckSkillUnlock = NULL; static BOOL g_skillUnlockHooked = NO;
static void *g_funcCanUseExSkill = NULL;   static BoolFunc4 g_origCanUseExSkill = NULL;   static BOOL g_canUseExSkillHooked = NO;
static void *g_funcIsExSkillInCD = NULL;   static BoolFunc4 g_origIsExSkillInCD = NULL;   static BOOL g_isExSkillInCDHooked = NO;
static void *g_funcLimitDmg = NULL;        static IntFunc1 g_origLimitDmg = NULL;         static BOOL g_limitHooked = NO;

// ============================================================
// 辅助函数: 清除普通技能CD
// ============================================================

/**
 * 清除指定技能的CD和恢复Count
 * characterField = CharacterFiled* (hook参数a2)
 * stateType = CharacterStateType (hook参数a1)
 *
 * CharacterSkillInfo.SkillN偏移计算:
 *   index = stateType - SKILL_INDEX_OFFSET (14-19 → 0-5)
 *   skillOffset = CF_SKILLINFO + SKILL_OFFSETS[index]
 *   CoolDown在skillOffset + SSD_COOLDOWN (FP, 8字节)
 *   Count在skillOffset + SSD_COUNT (Int16)
 */
static void clearSkillCD(void *characterField, int stateType) {
    if (!characterField) return;
    if (stateType < SKILL1 || stateType > SKILL6) return;

    int index = stateType - SKILL_INDEX_OFFSET;
    uint8_t *cf = (uint8_t*)characterField;
    uint8_t *skillInfo = cf + CF_SKILLINFO;
    uint8_t *skillData = skillInfo + SKILL_OFFSETS[index];

    // 清除CoolDown (FP=0, 8字节全零)
    uint64_t *cd = (uint64_t*)(skillData + SSD_COOLDOWN);
    *cd = 0;

    // 恢复Count到CountMax
    int16_t countMax = *(int16_t*)(skillData + SSD_COUNTMAX);
    if (countMax > 0) {
        *(int16_t*)(skillData + SSD_COUNT) = countMax;
    }

    jlog(@"clearSkillCD: stateType=%d index=%d cdCleared count=%d countMax=%d",
         stateType, index, *(int16_t*)(skillData + SSD_COUNT), countMax);
}

// ============================================================
// Hook函数实现
// ============================================================

/**
 * [1] 无CD: CheckSkillAttackCanUse
 * 签名: (Frame, CharacterStateType, CharacterFiled*, CharacterStatesAsset)
 * ARM64映射: self=x0=Frame*, a1=x1=stateType, a2=x2=characterField*, a3=x3=states
 *
 * 策略: 先清除CoolDown, 再调用原函数让它自己判断
 */
static int g_cdLogCount = 0;
static BOOL hookCanUse(void *self, int a1, int a2, int a3) {
    if (g_noCD) {
        int stateType = a1;
        if (stateType >= SKILL1 && stateType <= SKILL6) {
            void *characterField = (void*)(uintptr_t)a2;
            // 调试: 前3次dump SkillInfo区域的内存
            if (g_cdLogCount < 3 && characterField) {
                g_cdLogCount++;
                uint8_t *cf = (uint8_t*)characterField;
                uint8_t *si = cf + CF_SKILLINFO;
                jlog(@"CanUse DUMP[%d]: stateType=%d cf=%p", g_cdLogCount, stateType, characterField);
                jlog(@"  SkillInfo+0x40-0x4F: %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x",
                     si[0x40],si[0x41],si[0x42],si[0x43],si[0x44],si[0x45],si[0x46],si[0x47],
                     si[0x48],si[0x49],si[0x4A],si[0x4B],si[0x4C],si[0x4D],si[0x4E],si[0x4F]);
                jlog(@"  CoolDown@+0x48=0x%llx CoolDown@+0x38=0x%llx",
                     *(uint64_t*)(si+0x48), *(uint64_t*)(si+0x38));
                // Count@+0x44, CountMax@+0x46 (无header偏移)
                jlog(@"  Count@+0x44=%d CountMax@+0x46=%d Count@+0x54=%d CountMax@+0x56=%d",
                     *(int16_t*)(si+0x44), *(int16_t*)(si+0x46),
                     *(int16_t*)(si+0x54), *(int16_t*)(si+0x56));
            }
            clearSkillCD(characterField, stateType);
        }
    }
    if (g_origCanUse) return g_origCanUse(self, a1, a2, a3);
    return YES;
}

/**
 * [2] 无能量: CheckSkillIsReady
 * 签名: (Frame, CharacterStateType, CharacterFiled*, CharacterStatesAsset)
 * ARM64映射: self=x0=Frame*, a1=x1=stateType, a2=x2=characterField*, a3=x3=states
 *
 * 策略: 先清除CoolDown+恢复Count, 再调用原函数让它自己判断
 * 不再强制返回true! 让原函数判断
 */
static int g_energyLogCount = 0;
static BOOL hookIsReady(void *self, int a1, int a2, int a3) {
    if (g_noEnergy) {
        int stateType = a1;
        if (stateType >= SKILL1 && stateType <= SKILL6) {
            void *characterField = (void*)(uintptr_t)a2;
            clearSkillCD(characterField, stateType);
        }
        // 调试日志: 前10次记录参数和原函数返回值
        if (g_energyLogCount < 10) {
            g_energyLogCount++;
            BOOL origRet = g_origIsReady ? g_origIsReady(self, a1, a2, a3) : YES;
            jlog(@"IsReady[%d]: stateType=%d cf=%p origRet=%d (清除CD后原函数返回)", g_energyLogCount, stateType, (void*)(uintptr_t)a2, origRet);
            return origRet;
        }
    }
    if (g_origIsReady) return g_origIsReady(self, a1, a2, a3);
    return YES;
}

/**
 * [3] 忽略解锁: CheckSkillUnlock → true
 * 签名: (Frame, CharacterFiled*, CharacterStateType)
 * ARM64映射: self=x0=Frame*, a1=x1=characterField*, a2=x2=stateType, a3=x3(unused)
 * 注意: stateType在a2(第三个参数)!
 *
 * 解锁是UI层检查, 不涉及帧同步, 可以安全返回true
 */
static int g_unlockLogCount = 0;
static BOOL hookCheckSkillUnlock(void *self, int a1, int a2, int a3) {
    if (g_ignoreUnlock) {
        // 调试日志: 前10次记录参数
        if (g_unlockLogCount < 10) {
            g_unlockLogCount++;
            jlog(@"Unlock[%d]: a1=%d a2=%d (stateType在a2)", g_unlockLogCount, a1, a2);
        }
        return YES;
    }
    if (g_origCheckSkillUnlock) return g_origCheckSkillUnlock(self, a1, a2, a3);
    return YES;
}

/**
 * [4] 大招可用: CanUseExSkill → true
 * 签名: (Int64 customParam, Int32 usedTimesPack, Int32 exSkillIdx)
 * 这个检查的是使用次数, 不涉及帧同步状态, 可以安全返回true
 */
static BOOL hookCanUseExSkill(void *self, int a1, int a2, int a3) {
    if (g_exSkillAvail) return YES;
    if (g_origCanUseExSkill) return g_origCanUseExSkill(self, a1, a2, a3);
    return YES;
}

/**
 * [5] 大招无CD+无限怒气: IsExSkillInCD
 * 签名: (FP now, ExSkillData* skillp, ExSkillInfo info)
 * ARM64映射: self=x0=now(FP), a1=x1=ExSkillData*, a2=x2=ExSkillInfo
 *
 * 策略: 修改ExSkillData底层数据让大招可用
 *   1. lv = 30 → 等级足够
 *   2. Data = FP极大值 → 怒气满
 *   3. LastTriggerTime = 0 → CD已过
 * 然后返回NO(不在CD)
 *
 * 注意: 偏移使用dump.cs偏移-0x10(值类型无header)
 *   如果偏移错误, 日志中的内存dump会帮助判断
 */
static int g_exSkillLogCount = 0;  // 限制日志输出次数
static BOOL hookIsExSkillInCD(void *self, int a1, int a2, int a3) {
    if (g_exSkillNoCD) {
        void *skillpData = (void*)(uintptr_t)a1;
        if (skillpData) {
            // 调试: 前5次调用时dump整个ExSkillData内存区域
            if (g_exSkillLogCount < 5) {
                g_exSkillLogCount++;
                uint8_t *p = (uint8_t*)skillpData;
                jlog(@"ExSkillData DUMP[%d] ptr=%p:", g_exSkillLogCount, skillpData);
                jlog(@"  +00: %02x %02x %02x %02x %02x %02x %02x %02x  %02x %02x %02x %02x %02x %02x %02x %02x",
                     p[0],p[1],p[2],p[3],p[4],p[5],p[6],p[7],
                     p[8],p[9],p[10],p[11],p[12],p[13],p[14],p[15]);
                jlog(@"  +10: %02x %02x %02x %02x %02x %02x %02x %02x  %02x %02x %02x %02x %02x %02x %02x %02x",
                     p[16],p[17],p[18],p[19],p[20],p[21],p[22],p[23],
                     p[24],p[25],p[26],p[27],p[28],p[29],p[30],p[31]);
                // 解析两种偏移方案
                jlog(@"  方案A(无header): lv=%d id=%d Data64=0x%llx LTT64=0x%llx",
                     *(int16_t*)(p+0x00), *(int32_t*)(p+0x04),
                     *(uint64_t*)(p+0x08), *(uint64_t*)(p+0x10));
                jlog(@"  方案B(有header): lv=%d id=%d Data64=0x%llx LTT64=0x%llx",
                     *(int16_t*)(p+0x10), *(int32_t*)(p+0x14),
                     *(uint64_t*)(p+0x18), *(uint64_t*)(p+0x20));
            }

            // 1. 设置lv为30, 解决"等级不够"问题
            *(int16_t*)((uint8_t*)skillpData + ESD_LV) = 30;

            // 2. 设置Data为FP极大值 = 加满怒气
            // Deterministic.FP是定点数, 格式为: 值 = raw >> 16
            // FP(10000) = 10000 << 16 = 0x0000271000000000
            uint64_t *dataVal = (uint64_t*)((uint8_t*)skillpData + ESD_DATA);
            *dataVal = (uint64_t)10000 << 16;  // FP(10000) = 10000.0

            // 3. 清除LastTriggerTime
            uint64_t *ltt = (uint64_t*)((uint8_t*)skillpData + ESD_LASTTRIGGERTIME);
            *ltt = 0;

            jlog(@"ExSkillData SET: lv=%d id=%d Data=0x%llx LTT=0x%llx",
                 *(int16_t*)((uint8_t*)skillpData + ESD_LV),
                 *(int32_t*)((uint8_t*)skillpData + ESD_ID),
                 *dataVal, *ltt);
        }
        return NO; // 不在CD
    }
    if (g_origIsExSkillInCD) return g_origIsExSkillInCD(self, a1, a2, a3);
    return NO;
}

/** [6] 伤害上限: get_limitDamage → g_damageLimit */
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
    jlog(@"=== v13.0 IL2CPP Runtime Search ===");

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

                if (strcmp(n, "CheckSkillAttackCanUse") == 0 && !g_funcCanUse) {
                    jlog(@"FOUND %s.CheckSkillAttackCanUse params=%u addr=%p [1.无CD]", cn ?: "?", pc, funcAddr);
                    g_funcCanUse = funcAddr; found++;
                }
                else if (strcmp(n, "CheckSkillIsReady") == 0 && !g_funcIsReady) {
                    jlog(@"FOUND %s.CheckSkillIsReady params=%u addr=%p [2.无能量]", cn ?: "?", pc, funcAddr);
                    g_funcIsReady = funcAddr; found++;
                }
                else if (strcmp(n, "CheckSkillUnlock") == 0 && !g_funcCheckSkillUnlock) {
                    jlog(@"FOUND %s.CheckSkillUnlock params=%u addr=%p [3.忽略解锁]", cn ?: "?", pc, funcAddr);
                    g_funcCheckSkillUnlock = funcAddr; found++;
                }
                else if (strcmp(n, "CanUseExSkill") == 0 && !g_funcCanUseExSkill) {
                    jlog(@"FOUND %s.CanUseExSkill params=%u addr=%p [4.大招可用]", cn ?: "?", pc, funcAddr);
                    g_funcCanUseExSkill = funcAddr; found++;
                }
                else if (strcmp(n, "IsExSkillInCD") == 0 && !g_funcIsExSkillInCD) {
                    jlog(@"FOUND %s.IsExSkillInCD params=%u addr=%p [5.大招无CD]", cn ?: "?", pc, funcAddr);
                    g_funcIsExSkillInCD = funcAddr; found++;
                }
                else if (strcmp(n, "get_limitDamage") == 0 && !g_funcLimitDmg) {
                    jlog(@"FOUND %s.get_limitDamage params=%u addr=%p [6.伤害上限]", cn ?: "?", pc, funcAddr);
                    g_funcLimitDmg = funcAddr; found++;
                }
            }
        }
    }

    jlog(@"Scanned %d methods, found %d targets", totalMethods, found);
    jlog(@"[1]CanUse=%p [2]IsReady=%p [3]CheckSkillUnlock=%p", g_funcCanUse, g_funcIsReady, g_funcCheckSkillUnlock);
    jlog(@"[4]CanUseExSkill=%p [5]IsExSkillInCD=%p [6]LimitDmg=%p", g_funcCanUseExSkill, g_funcIsExSkillInCD, g_funcLimitDmg);
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
    if (!g_funcCanUse) findIL2CPP();

    // 所有hook一开始就全部安装, 开关只控制hook函数内部逻辑
    hookOneFunc(g_funcCanUse, hookCanUse, (void**)&g_origCanUse, &g_cdHooked, "1.无CD");
    hookOneFunc(g_funcIsReady, hookIsReady, (void**)&g_origIsReady, &g_energyHooked, "2.无能量");
    hookOneFunc(g_funcCheckSkillUnlock, hookCheckSkillUnlock, (void**)&g_origCheckSkillUnlock, &g_skillUnlockHooked, "3.忽略解锁");
    hookOneFunc(g_funcCanUseExSkill, hookCanUseExSkill, (void**)&g_origCanUseExSkill, &g_canUseExSkillHooked, "4.大招可用");
    hookOneFunc(g_funcIsExSkillInCD, hookIsExSkillInCD, (void**)&g_origIsExSkillInCD, &g_isExSkillInCDHooked, "5.大招无CD");
    hookOneFunc(g_funcLimitDmg, hookLimitDmg, (void**)&g_origLimitDmg, &g_limitHooked, "6.伤害上限");

    jlog(@"applyAllHooks done (v13.0 - 数据修改策略: 修改底层数据让原函数自己返回正确值)");
}

// ============================================================
// UI
// ============================================================

static UIView *g_panel = nil;
static UIButton *g_btnNoCD = nil;
static UIButton *g_btnNoEnergy = nil;
static UIButton *g_btnIgnoreUnlock = nil;
static UIButton *g_btnExSkillAvail = nil;
static UIButton *g_btnExSkillNoCD = nil;
static UISlider *g_slider = nil;
static UILabel *g_sliderLabel = nil;
static BOOL g_panelOpen = NO;

static void refreshButtons(void) {
    [g_btnNoCD setTitle: g_noCD ? @"\U00002705 \u65e0CD" : @"\U0000274c \u65e0CD" forState:UIControlStateNormal];
    g_btnNoCD.backgroundColor = g_noCD ? [UIColor colorWithRed:0.15 green:0.75 blue:0.15 alpha:0.95] : [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:0.95];

    [g_btnNoEnergy setTitle: g_noEnergy ? @"\U00002705 \u65e0\u80fd\u91cf" : @"\U0000274c \u65e0\u80fd\u91cf" forState:UIControlStateNormal];
    g_btnNoEnergy.backgroundColor = g_noEnergy ? [UIColor colorWithRed:0.15 green:0.75 blue:0.15 alpha:0.95] : [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:0.95];

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
    CGFloat pw=260, ph=310;
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
- (void)onNoCD;
- (void)onNoEnergy;
- (void)onIgnoreUnlock;
- (void)onExSkillAvail;
- (void)onExSkillNoCD;
- (void)sliderChanged:(UISlider *)slider;
@end
@implementation JYJHActionHandler
+ (instancetype)shared { static JYJHActionHandler *s; static dispatch_once_t o; dispatch_once(&o,^{s=[[self alloc]init];}); return s; }
- (void)onNoCD { g_noCD=!g_noCD; refreshButtons(); jlog(@"Toggle 无CD: %d", g_noCD); }
- (void)onNoEnergy { g_noEnergy=!g_noEnergy; refreshButtons(); jlog(@"Toggle 无能量: %d", g_noEnergy); }
- (void)onIgnoreUnlock { g_ignoreUnlock=!g_ignoreUnlock; refreshButtons(); jlog(@"Toggle 忽略解锁: %d", g_ignoreUnlock); }
- (void)onExSkillAvail { g_exSkillAvail=!g_exSkillAvail; refreshButtons(); jlog(@"Toggle 大招可用: %d", g_exSkillAvail); }
- (void)onExSkillNoCD { g_exSkillNoCD=!g_exSkillNoCD; refreshButtons(); jlog(@"Toggle 大招无CD: %d", g_exSkillNoCD); }
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

    CGFloat pw=260, ph=310;
    g_panel=[[UIView alloc]initWithFrame:CGRectMake(0,0,pw,ph)];
    g_panel.backgroundColor=[UIColor colorWithRed:0.08 green:0.08 blue:0.12 alpha:0.98];
    g_panel.layer.cornerRadius=14; g_panel.hidden=YES; [win addSubview:g_panel];

    UILabel *title=[[UILabel alloc]initWithFrame:CGRectMake(0,8,pw,22)];
    title.text=@"\u5251\u5f71\u6c5f\u6e56 v13.0"; title.textColor=[UIColor cyanColor];
    title.font=[UIFont boldSystemFontOfSize:14]; title.textAlignment=NSTextAlignmentCenter; [g_panel addSubview:title];

    CGFloat bx=16, bw=228, bh=32, by0=34, bdy=36;
    g_btnNoCD=[UIButton buttonWithType:UIButtonTypeCustom]; g_btnNoCD.frame=CGRectMake(bx,by0,bw,bh);
    g_btnNoCD.layer.cornerRadius=8; g_btnNoCD.titleLabel.font=[UIFont boldSystemFontOfSize:13];
    [g_btnNoCD addTarget:[JYJHActionHandler shared] action:@selector(onNoCD) forControlEvents:UIControlEventTouchUpInside]; [g_panel addSubview:g_btnNoCD];

    g_btnNoEnergy=[UIButton buttonWithType:UIButtonTypeCustom]; g_btnNoEnergy.frame=CGRectMake(bx,by0+bdy,bw,bh);
    g_btnNoEnergy.layer.cornerRadius=8; g_btnNoEnergy.titleLabel.font=[UIFont boldSystemFontOfSize:13];
    [g_btnNoEnergy addTarget:[JYJHActionHandler shared] action:@selector(onNoEnergy) forControlEvents:UIControlEventTouchUpInside]; [g_panel addSubview:g_btnNoEnergy];

    g_btnIgnoreUnlock=[UIButton buttonWithType:UIButtonTypeCustom]; g_btnIgnoreUnlock.frame=CGRectMake(bx,by0+bdy*2,bw,bh);
    g_btnIgnoreUnlock.layer.cornerRadius=8; g_btnIgnoreUnlock.titleLabel.font=[UIFont boldSystemFontOfSize:13];
    [g_btnIgnoreUnlock addTarget:[JYJHActionHandler shared] action:@selector(onIgnoreUnlock) forControlEvents:UIControlEventTouchUpInside]; [g_panel addSubview:g_btnIgnoreUnlock];

    g_btnExSkillAvail=[UIButton buttonWithType:UIButtonTypeCustom]; g_btnExSkillAvail.frame=CGRectMake(bx,by0+bdy*3,bw,bh);
    g_btnExSkillAvail.layer.cornerRadius=8; g_btnExSkillAvail.titleLabel.font=[UIFont boldSystemFontOfSize:13];
    [g_btnExSkillAvail addTarget:[JYJHActionHandler shared] action:@selector(onExSkillAvail) forControlEvents:UIControlEventTouchUpInside]; [g_panel addSubview:g_btnExSkillAvail];

    g_btnExSkillNoCD=[UIButton buttonWithType:UIButtonTypeCustom]; g_btnExSkillNoCD.frame=CGRectMake(bx,by0+bdy*4,bw,bh);
    g_btnExSkillNoCD.layer.cornerRadius=8; g_btnExSkillNoCD.titleLabel.font=[UIFont boldSystemFontOfSize:13];
    [g_btnExSkillNoCD addTarget:[JYJHActionHandler shared] action:@selector(onExSkillNoCD) forControlEvents:UIControlEventTouchUpInside]; [g_panel addSubview:g_btnExSkillNoCD];

    CGFloat sy = by0 + bdy*5 + 4;
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

    jlog(@"========== JYJH v13.0 (数据修改策略) ==========");
    jlog(@"iOS %@", [[UIDevice currentDevice] systemVersion]);
    jlog(@"Bundle %@", [[NSBundle mainBundle] bundleIdentifier]);
    jlog(@"v13.0: 不再强制返回true! 改为修改底层数据让原函数自己返回正确值");
    jlog(@"  无CD/无能量: 清除SkillStateData.CoolDown+恢复Count, 然后调原函数");
    jlog(@"  大招: 修改ExSkillData.lv=30 + Data(怒气)=极大值 + LastTriggerTime=0");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(5.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        jlog(@"5s delay done, applying hooks...");
        applyAllHooks();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            setupUI();
        });
    });
}
