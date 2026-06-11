/**
 * 剑影江湖 v18.0 - 修复数据访问 + 增加调试信息
 *
 * v17日志关键发现：
 *   1. TryTriggerExSkill被调用了！type=1024(Skill6) ✅
 *   2. get_ExSkillDatas()=69440(0x10f40) ✅  (v15.1是0x8f60，不同是因为不同战斗)
 *   3. ResolveList返回了QListInternal ✅
 *   4. TryGetExSkillDataPointer失败了（走了fallback）
 *   5. Fallback: count=2(第一次)/1(第二次), stride=0x4 ❌ (期望0x20!)
 *      → stride=4说明这不是ExSkillData的QList，而是Int32列表！
 *
 * 根因分析：
 *   get_ExSkillDatas()返回的QListPtr<ExSkillData>的Offset
 *   指向的QListInternal包含的不是ExSkillData数组，而是Int32列表！
 *   stride=0x4 = sizeof(Int32)，不是0x20=sizeof(ExSkillData)
 *   → 这说明ExSkillDatas存储的是ExSkillData的ID列表，不是ExSkillData本身！
 *
 *   实际上ExSkillData是值类型，嵌入在CharacterFiled结构体中
 *   QListPtr<ExSkillData>可能存储的是引用/ID，不是完整的ExSkillData
 *   真正的ExSkillData数组可能在CharacterFiled内部，通过Ptr间接访问
 *
 *   回看dump.cs:
 *   CharacterFiled有ExSkillDatasPtr(+0x28)字段，类型是Ptr
 *   get_ExSkillDatas()返回QListPtr<ExSkillData>，实际就是Ptr+0x28
 *   但QListInternal的stride=4，说明QList里存的是Int32(可能是ExSkillData的id/索引)
 *
 *   那ExSkillData在哪里？
 *   - TryGetExSkillDataPointer能直接获取ExSkillData指针
 *   - 但它的参数需要id(ExSkillData的id)
 *   - id从QListInternal中读取！
 *
 * v18策略：
 *   1. 从QListInternal读取ExSkillData的id列表(stride=4的Int32数组)
 *   2. 用每个id调用TryGetExSkillDataPointer获取对应的ExSkillData指针
 *   3. 直接修改ExSkillData的Data(怒气)字段
 *   4. 关键：需要知道QListInternal中数据指针的正确偏移
 *      QBuffer: Length(+0x10), Stride(+0x14), Ptr.Offset(+0x18+0x10)
 *      但stride=4的数据数组地址怎么算？
 *      用ResolveList(Ptr.Offset)得到的是QListInternal，不是原始数据
 *      需要进一步解析QBuffer中的Ptr来获取数据数组
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
// 数据结构偏移
// ============================================================

// ExSkillData (值类型, dump.cs偏移-0x10):
// lv=0x00(Int16), id=0x04(Int32), Data=0x08(FP8字节=怒气),
// LastTriggerTime=0x10(FP8字节), skills=0x18(UInt64), SIZE=0x20
static const int ESD_LV = 0x00;
static const int ESD_ID = 0x04;
static const int ESD_DATA = 0x08;
static const int ESD_LASTTRIGGERTIME = 0x10;
static const int ESD_SKILLS = 0x18;
static const int ESD_SIZE = 0x20;

// ============================================================
// Hook函数指针
// ============================================================

typedef BOOL (*BoolFunc3)(void*, int, int);
typedef int  (*IntFunc1)(void*);
typedef BOOL (*BoolFunc8)(void*, uint64_t, void*, void*, void*, void*, void*, uint64_t);
typedef BOOL (*BoolFunc7)(void*, uint64_t, void*, uint64_t, void*, void*, int);
typedef int32_t (*GetExSkillDatasFunc)(void*);
typedef void* (*ResolveListFunc)(void*, int32_t);
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
// 辅助：修改ExSkillData怒气（v18修复版）
// ============================================================

/**
 * v18核心修复：QListInternal的stride=4说明存的是Int32 id列表
 * 真正的ExSkillData通过TryGetExSkillDataPointer(character, frame, id, &ptr)获取
 *
 * 步骤：
 * 1. get_ExSkillDatas() → QListPtr.Offset (0x10f40)
 * 2. ResolveList(f, offset) → QListInternal*
 * 3. QListInternal._count → ExSkillData数量
 * 4. QListInternal._items(QBuffer).Ptr.Offset → id数组的Offset
 * 5. heap_base + id_array_offset → Int32[] ids
 * 6. 对每个id: TryGetExSkillDataPointer(char, f, id, &ptr) → ExSkillData*
 * 7. 修改ExSkillData.Data(怒气)为极大值
 */
static void fillExSkillAnger(void *f, void *character) {
    if (!g_funcGetExSkillDatas || !character || !f) return;

    int32_t listOffset = g_funcGetExSkillDatas(character);

    static int apiLogCount = 0;
    if (apiLogCount < 30) {
        apiLogCount++;
        jlog(@"fillAnger[%d]: listOffset=%d (0x%x)", apiLogCount, listOffset, listOffset);
    }

    if (listOffset <= 0) return;

    // 获取QListInternal
    if (!g_funcResolveList) return;
    void *qListInternal = g_funcResolveList(f, listOffset);
    if (!qListInternal) {
        jlog(@"fillAnger: ResolveList returned NULL");
        return;
    }

    // dump QListInternal前0x30字节（调试）
    uint8_t *qlp = (uint8_t*)qListInternal;
    jlog(@"fillAnger: QListInternal=%p DUMP: %02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x",
         qListInternal,
         qlp[0],qlp[1],qlp[2],qlp[3], qlp[4],qlp[5],qlp[6],qlp[7],
         qlp[8],qlp[9],qlp[10],qlp[11], qlp[12],qlp[13],qlp[14],qlp[15]);
    jlog(@"fillAnger: +0x10: %02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x",
         qlp[16],qlp[17],qlp[18],qlp[19], qlp[20],qlp[21],qlp[22],qlp[23],
         qlp[24],qlp[25],qlp[26],qlp[27], qlp[28],qlp[29],qlp[30],qlp[31]);

    // 读取QListInternal字段
    // QListInternal结构: _count(+0x10), _items(QBuffer)(+0x14)
    int32_t count = *(int32_t*)(qlp + 0x10);

    // QBuffer在+0x14处
    uint8_t *qbuf = qlp + 0x14;
    int32_t bufLength = *(int32_t*)(qbuf + 0x10);  // QBuffer.Length
    int32_t bufStride = *(int32_t*)(qbuf + 0x14);  // QBuffer.Stride
    // QBuffer.Ptr at +0x18, Ptr.Offset at Ptr+0x10
    int32_t dataPtrOffset = *(int32_t*)(qbuf + 0x18 + 0x10);  // 数据数组的Offset

    jlog(@"fillAnger: count=%d bufLen=%d bufStride=%d dataPtrOff=%d",
         count, bufLength, bufStride, dataPtrOffset);

    if (count <= 0 || count > 20) return;

    // v17发现stride=4，说明QList存的是Int32（ExSkillData的id）
    // 但也可能是我对QListInternal结构的理解有误
    // 让我直接dump QBuffer+0x18处（Ptr结构）的完整内容
    jlog(@"fillAnger: QBuffer.Ptr dump: %02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x",
         qbuf[0x18],qbuf[0x19],qbuf[0x1a],qbuf[0x1b],
         qbuf[0x1c],qbuf[0x1d],qbuf[0x1e],qbuf[0x1f],
         qbuf[0x20],qbuf[0x21],qbuf[0x22],qbuf[0x23],
         qbuf[0x24],qbuf[0x25],qbuf[0x26],qbuf[0x27],
         qbuf[0x28],qbuf[0x29],qbuf[0x2a],qbuf[0x2b],
         qbuf[0x2c],qbuf[0x2d],qbuf[0x2e],qbuf[0x2f]);

    // 策略A：如果stride=4(Int32 id列表)，读取id后用TryGetExSkillDataPointer
    if (bufStride == 4 && dataPtrOffset > 0 && g_funcTryGetExSkillDataPointer) {
        // 计算id数组地址: heap_base + dataPtrOffset
        // heap_base = qListInternal - listOffset
        uint8_t *heapBase = (uint8_t*)qListInternal - listOffset;
        int32_t *idArray = (int32_t*)(heapBase + dataPtrOffset);

        jlog(@"fillAnger: idArray at %p, ids:", idArray);
        for (int i = 0; i < count && i < 10; i++) {
            int32_t skillId = idArray[i];
            jlog(@"fillAnger: id[%d]=%d", i, skillId);
        }

        // 用每个id获取ExSkillData指针
        for (int i = 0; i < count && i < 10; i++) {
            int32_t skillId = idArray[i];
            if (skillId <= 0) continue;

            void *exSkillPtr = NULL;
            BOOL result = g_funcTryGetExSkillDataPointer(character, f, skillId, &exSkillPtr);

            if (result && exSkillPtr) {
                // 读取并修改ExSkillData
                int16_t lv = *(int16_t*)((uint8_t*)exSkillPtr + ESD_LV);
                int32_t id = *(int32_t*)((uint8_t*)exSkillPtr + ESD_ID);
                uint64_t data = *(uint64_t*)((uint8_t*)exSkillPtr + ESD_DATA);
                uint64_t lastTime = *(uint64_t*)((uint8_t*)exSkillPtr + ESD_LASTTRIGGERTIME);

                jlog(@"fillAnger: ExSkill[%d] id=%d lv=%d data=0x%llx lastTime=0x%llx → modifying",
                     i, id, lv, data, lastTime);

                // 修改怒气为极大值
                *(uint64_t*)((uint8_t*)exSkillPtr + ESD_DATA) = (uint64_t)10000 << 16;
                // 清除CD
                *(uint64_t*)((uint8_t*)exSkillPtr + ESD_LASTTRIGGERTIME) = 0;
                // 等级设为30
                *(int16_t*)((uint8_t*)exSkillPtr + ESD_LV) = 30;

                jlog(@"fillAnger: ExSkill[%d] modified: anger=max cd=0 lv=30", i);
            } else {
                jlog(@"fillAnger: TryGetPtr(id=%d) failed result=%d ptr=%p", skillId, result, exSkillPtr);
            }
        }
        return;
    }

    // 策略B：如果stride=0x20(ExSkillData直接存储)
    if (bufStride == ESD_SIZE && dataPtrOffset > 0) {
        uint8_t *heapBase = (uint8_t*)qListInternal - listOffset;
        uint8_t *exDataArray = heapBase + dataPtrOffset;

        int32_t firstId = *(int32_t*)(exDataArray + ESD_ID);
        jlog(@"fillAnger stride=0x20: firstId=%d", firstId);

        if (firstId > 0 && firstId < 100000) {
            for (int i = 0; i < count && i < 10; i++) {
                uint8_t *p = exDataArray + i * ESD_SIZE;
                int32_t curId = *(int32_t*)(p + ESD_ID);
                if (curId == 0 && i > 0) break;
                *(uint64_t*)(p + ESD_DATA) = (uint64_t)10000 << 16;
                *(uint64_t*)(p + ESD_LASTTRIGGERTIME) = 0;
                *(int16_t*)(p + ESD_LV) = 30;
                jlog(@"fillAnger[%d] direct: id=%d modified", i, curId);
            }
            return;
        }
    }

    // 策略C：完全不知道结构，暴力尝试用id=1,2,3...调用TryGetExSkillDataPointer
    if (g_funcTryGetExSkillDataPointer) {
        jlog(@"fillAnger: brute-force TryGetPtr with ids 1-10");
        for (int32_t id = 1; id <= 10; id++) {
            void *exSkillPtr = NULL;
            BOOL result = g_funcTryGetExSkillDataPointer(character, f, id, &exSkillPtr);
            if (result && exSkillPtr) {
                int32_t foundId = *(int32_t*)((uint8_t*)exSkillPtr + ESD_ID);
                uint64_t data = *(uint64_t*)((uint8_t*)exSkillPtr + ESD_DATA);
                jlog(@"fillAnger brute: id=%d → foundId=%d data=0x%llx → modifying", id, foundId, data);

                *(uint64_t*)((uint8_t*)exSkillPtr + ESD_DATA) = (uint64_t)10000 << 16;
                *(uint64_t*)((uint8_t*)exSkillPtr + ESD_LASTTRIGGERTIME) = 0;
                *(int16_t*)((uint8_t*)exSkillPtr + ESD_LV) = 30;
            }
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
            jlog(@"CanUseExSkill[%d]: a1=%d a2=%d", g_canUseLogCount, a1, a2);
        }
        return YES;
    }
    if (g_origCanUseExSkill) return g_origCanUseExSkill(self, a1, a2);
    return YES;
}

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

static int g_orAddLogCount = 0;
static BOOL hookTriggerExSkillOrAdd(void *f, uint64_t trigger, void *character,
                                     uint64_t now, void *info, void *asset, int lv) {
    if (g_orAddLogCount < 30) {
        g_orAddLogCount++;
        jlog(@"OrAdd[%d] f=%p char=%p now=0x%llx lv=%d noCD=%d",
             g_orAddLogCount, f, character, now, lv, g_exSkillNoCD);
    }

    if (g_exSkillNoCD && character && f) {
        fillExSkillAnger(f, character);
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
    jlog(@"=== v18.0 IL2CPP Runtime Search ===");

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
                    jlog(@"FOUND %s.CheckSkillUnlock params=%u addr=%p", cn ?: "?", pc, funcAddr);
                    g_funcCheckSkillUnlock = funcAddr; found++;
                }
                else if (strcmp(n, "CanUseExSkill") == 0 && !g_funcCanUseExSkill) {
                    jlog(@"FOUND %s.CanUseExSkill params=%u addr=%p", cn ?: "?", pc, funcAddr);
                    g_funcCanUseExSkill = funcAddr; found++;
                }
                else if (strcmp(n, "TryTriggerExSkill") == 0 && !g_funcTryTriggerExSkill) {
                    jlog(@"FOUND %s.TryTriggerExSkill params=%u addr=%p", cn ?: "?", pc, funcAddr);
                    g_funcTryTriggerExSkill = funcAddr; found++;
                }
                else if (strcmp(n, "TriggerExSkillOrAdd") == 0 && !g_funcTriggerExSkillOrAdd) {
                    jlog(@"FOUND %s.TriggerExSkillOrAdd params=%u addr=%p", cn ?: "?", pc, funcAddr);
                    g_funcTriggerExSkillOrAdd = funcAddr; found++;
                }
                else if (strcmp(n, "get_limitDamage") == 0 && !g_funcLimitDmg) {
                    jlog(@"FOUND %s.get_limitDamage params=%u addr=%p", cn ?: "?", pc, funcAddr);
                    g_funcLimitDmg = funcAddr; found++;
                }
                else if (strcmp(n, "get_ExSkillDatas") == 0 && !g_funcGetExSkillDatas) {
                    jlog(@"FOUND %s.get_ExSkillDatas params=%u addr=%p", cn ?: "?", pc, funcAddr);
                    g_funcGetExSkillDatas = (GetExSkillDatasFunc)funcAddr; found++;
                }
                else if (strcmp(n, "TryGetExSkillDataPointer") == 0 && !g_funcTryGetExSkillDataPointer) {
                    jlog(@"FOUND %s.TryGetExSkillDataPointer params=%u addr=%p", cn ?: "?", pc, funcAddr);
                    g_funcTryGetExSkillDataPointer = (TryGetExSkillDataPointerFunc)funcAddr; found++;
                }
                else if (strcmp(n, "ResolveList") == 0 && !g_funcResolveList && cn && strcmp(cn, "FrameBase") == 0) {
                    jlog(@"FOUND %s.ResolveList params=%u addr=%p", cn ?: "?", pc, funcAddr);
                    g_funcResolveList = (ResolveListFunc)funcAddr; found++;
                }
            }
        }
    }

    jlog(@"Scanned %d methods, found %d targets", totalMethods, found);
    jlog(@"Unlock=%p CanUse=%p LimitDmg=%p TryTrigger=%p OrAdd=%p",
         g_funcCheckSkillUnlock, g_funcCanUseExSkill, g_funcLimitDmg, g_funcTryTriggerExSkill, g_funcTriggerExSkillOrAdd);
    jlog(@"GetExData=%p TryGetPtr=%p ResolveList=%p",
         (void*)g_funcGetExSkillDatas, (void*)g_funcTryGetExSkillDataPointer, (void*)g_funcResolveList);
}

// ============================================================
// Dobby Hook
// ============================================================

static void hookOneFunc(void *funcAddr, void *hookFunc, void **origFunc, BOOL *hookedFlag, const char *name) {
    if (!funcAddr) { jlog(@"%s: funcAddr not found", name); return; }
    if (*hookedFlag) { jlog(@"%s: already hooked", name); return; }
    int ret = DobbyHook(funcAddr, hookFunc, origFunc);
    if (ret == 0) {
        *hookedFlag = YES;
        jlog(@"%s: DobbyHook OK at %p, orig=%p", name, funcAddr, *origFunc);
    } else {
        jlog(@"%s: DobbyHook FAILED ret=%d", name, ret);
    }
}

static void applyAllHooks(void) {
    if (!g_funcCheckSkillUnlock) findIL2CPP();
    hookOneFunc(g_funcLimitDmg, hookLimitDmg, (void**)&g_origLimitDmg, &g_limitHooked, "3.伤害上限");
    jlog(@"applyAllHooks done");
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
    refreshButtons(); jlog(@"Toggle 忽略解锁: %d", g_ignoreUnlock);
}
- (void)onExSkillAvail {
    g_exSkillAvail=!g_exSkillAvail;
    if (g_exSkillAvail && !g_canUseExSkillHooked) {
        findIL2CPP();
        hookOneFunc(g_funcCanUseExSkill, hookCanUseExSkill, (void**)&g_origCanUseExSkill, &g_canUseExSkillHooked, "2.大招可用");
    }
    refreshButtons(); jlog(@"Toggle 大招可用: %d", g_exSkillAvail);
}
- (void)onExSkillNoCD {
    g_exSkillNoCD=!g_exSkillNoCD;
    if (g_exSkillNoCD) {
        findIL2CPP();
        if (!g_tryTriggerHooked)
            hookOneFunc(g_funcTryTriggerExSkill, hookTryTriggerExSkill, (void**)&g_origTryTriggerExSkill, &g_tryTriggerHooked, "4a.TryTrigger");
        if (!g_triggerOrAddHooked)
            hookOneFunc(g_funcTriggerExSkillOrAdd, hookTriggerExSkillOrAdd, (void**)&g_origTriggerExSkillOrAdd, &g_triggerOrAddHooked, "4b.OrAdd");
    }
    refreshButtons(); jlog(@"Toggle 大招无CD: %d TryTrigger=%d OrAdd=%d",
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
    title.text=@"\u5251\u5f71\u6c5f\u6e56 v18.0"; title.textColor=[UIColor cyanColor];
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

    jlog(@"========== JYJH v18.0 (修复ExSkillData数据访问) ==========");
    jlog(@"iOS %@", [[UIDevice currentDevice] systemVersion]);
    jlog(@"v18.0: QListInternal stride=4说明存的是ExSkillData ID列表");
    jlog(@"  修复: 读取id列表后用TryGetExSkillDataPointer获取真正的ExSkillData指针");
    jlog(@"  增加大量调试dump输出帮助定位数据结构");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(5.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        jlog(@"5s delay done");
        applyAllHooks();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            setupUI();
        });
    });
}
