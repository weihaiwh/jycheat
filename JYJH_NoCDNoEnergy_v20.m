/**
 * 剑影江湖 v20.0 - 关键修复：修改所有ExSkillData（去掉id<100000限制）
 *
 * v19日志关键发现：
 *   TryTrigger[1] type=1024 f=0x15b51d900 char=0x15e3c8828 noCD=1
 *   fillAnger: ExSkill[0] id=10020501 lv=1 data=0x0  ← 没被修改！(id>100000)
 *   fillAnger: ExSkill[1] id=50002 lv=3 data=0x0     ← 被修改了
 *   fillAnger: ExSkill[2] id=3000 lv=2 data=0x0      ← 被修改了
 *   fillAnger: ExSkill[3] id=3001 lv=1 data=0x0      ← 被修改了
 *
 * BUG: id=10020501是8位数，超过了v19的 id < 100000 判断！
 *   而TryTriggerExSkill的type=1024(Skill6)很可能对应的就是ExSkill[0]!
 *   所以我们修改了3个ExSkillData，但偏偏漏掉了最关键的那个！
 *
 * v20修复：
 *   1. 去掉id < 100000限制，修改所有ExSkillData
 *   2. 同时修改ExSkill[0](id=10020501)的Data为满怒气
 *   3. 增加详细日志：修改前后的完整hex dump
 *
 * 另一个重要分析：
 *   - v19中TryTriggerExSkill被调用了，我们修改了ExSkillData.Data
 *   - 但大招仍不释放 → 可能是修改后的值被帧同步回滚了
 *   - 或者原函数内部有其他检查条件
 *   - v20增加：修改后验证读回的值，确认写入成功
 *   - v20增加：在TryTriggerExSkill调用原函数后，检查原函数返回值
 */

#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <dispatch/dispatch.h>
#import <UIKit/UIKit.h>
#import <stdio.h>
#import <string.h>
#import <dlfcn.h>

#include "dobby.h"

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

static BOOL g_ignoreUnlock = NO;
static BOOL g_exSkillAvail = NO;
static BOOL g_exSkillNoCD = NO;
static int g_damageLimit = 100;

// ExSkillData偏移 (值类型嵌入时, dump.cs偏移-0x10):
// lv=0x00(Int16), id=0x04(Int32), Data=0x08(FP8字节=怒气),
// LastTriggerTime=0x10(FP8字节), skills=0x18(UInt64), SIZE=0x20
static const int ESD_LV = 0x00;
static const int ESD_ID = 0x04;
static const int ESD_DATA = 0x08;
static const int ESD_LASTTRIGGERTIME = 0x10;
static const int ESD_SKILLS = 0x18;
static const int ESD_SIZE = 0x20;

// QListInternal偏移 (值类型嵌入时, dump.cs偏移-0x10):
// _count=+0x00, _capacity=+0x04, _stride=+0x08, _itemsOffset=+0x0c
static const int QLI_COUNT = 0x00;
static const int QLI_CAPACITY = 0x04;
static const int QLI_STRIDE = 0x08;
static const int QLI_ITEMS_OFFSET = 0x0c;

typedef BOOL (*BoolFunc3)(void*, int, int);
typedef int  (*IntFunc1)(void*);
typedef BOOL (*BoolFunc8)(void*, uint64_t, void*, void*, void*, void*, void*, uint64_t);
typedef BOOL (*BoolFunc7)(void*, uint64_t, void*, uint64_t, void*, void*, int);
typedef int32_t (*GetExSkillDatasFunc)(void*);
typedef void* (*ResolveListFunc)(void*, int32_t);

static void *g_funcCheckSkillUnlock = NULL; static BoolFunc3 g_origCheckSkillUnlock = NULL; static BOOL g_skillUnlockHooked = NO;
static void *g_funcCanUseExSkill = NULL;    static BoolFunc3 g_origCanUseExSkill = NULL;    static BOOL g_canUseExSkillHooked = NO;
static void *g_funcTryTriggerExSkill = NULL; static BoolFunc8 g_origTryTriggerExSkill = NULL; static BOOL g_tryTriggerHooked = NO;
static void *g_funcTriggerExSkillOrAdd = NULL; static BoolFunc7 g_origTriggerExSkillOrAdd = NULL; static BOOL g_triggerOrAddHooked = NO;
static void *g_funcLimitDmg = NULL;         static IntFunc1 g_origLimitDmg = NULL;          static BOOL g_limitHooked = NO;

static GetExSkillDatasFunc g_funcGetExSkillDatas = NULL;
static ResolveListFunc g_funcResolveList = NULL;

// ============================================================
// 核心函数：修改ExSkillData怒气（v20 - 修改所有！）
// ============================================================

static void fillExSkillAnger(void *f, void *character) {
    if (!g_funcGetExSkillDatas || !character || !f) return;

    // Step 1: 获取ExSkillDatas的QListPtr.Offset
    int32_t listOffset = g_funcGetExSkillDatas(character);

    static int apiLogCount = 0;
    if (apiLogCount < 50) {
        apiLogCount++;
        jlog(@"fillAnger[%d]: listOffset=%d (0x%x)", apiLogCount, listOffset, listOffset);
    }

    if (listOffset <= 0) return;

    // Step 2: 用ResolveList获取QListInternal*
    if (!g_funcResolveList) return;
    void *qListInternal = g_funcResolveList(f, listOffset);
    if (!qListInternal) {
        jlog(@"fillAnger: ResolveList returned NULL");
        return;
    }

    uint8_t *qlp = (uint8_t*)qListInternal;

    // Step 3: 读取QListInternal字段
    int32_t count = *(int32_t*)(qlp + QLI_COUNT);
    int32_t capacity = *(int32_t*)(qlp + QLI_CAPACITY);
    int32_t stride = *(int32_t*)(qlp + QLI_STRIDE);
    int32_t itemsOffset = *(int32_t*)(qlp + QLI_ITEMS_OFFSET);

    jlog(@"fillAnger: QListInternal=%p count=%d cap=%d stride=0x%x itemsOff=0x%x",
         qListInternal, count, capacity, stride, itemsOffset);

    if (count <= 0 || count > 20) {
        jlog(@"fillAnger: count=%d invalid", count);
        return;
    }

    if (itemsOffset <= 0) {
        jlog(@"fillAnger: itemsOffset=%d invalid", itemsOffset);
        return;
    }

    // Step 4: 计算ExSkillData数组地址
    uint8_t *heapBase = (uint8_t*)qListInternal - listOffset;
    uint8_t *exDataArray = heapBase + itemsOffset;

    jlog(@"fillAnger: heapBase=%p exDataArray=%p", heapBase, exDataArray);

    // Step 5: 修改所有ExSkillData（v20关键修复：去掉id限制！）
    if (stride == ESD_SIZE) {
        for (int i = 0; i < count && i < 10; i++) {
            uint8_t *p = exDataArray + i * ESD_SIZE;

            int16_t lv = *(int16_t*)(p + ESD_LV);
            int32_t id = *(int32_t*)(p + ESD_ID);
            uint64_t data = *(uint64_t*)(p + ESD_DATA);
            uint64_t lastTime = *(uint64_t*)(p + ESD_LASTTRIGGERTIME);

            jlog(@"fillAnger: ESD[%d] id=%d lv=%d data=0x%llx lastTime=0x%llx",
                 i, id, lv, data, lastTime);

            // v20修复：修改所有ExSkillData，不限id范围！
            // 只要id!=0（有效数据）就修改
            if (id != 0) {
                // 修改怒气为极大值: FP(10000) = 10000 << 16 = 0x27100000
                uint64_t newAnger = (uint64_t)10000 << 16;
                *(uint64_t*)(p + ESD_DATA) = newAnger;
                // 清除CD
                *(uint64_t*)(p + ESD_LASTTRIGGERTIME) = 0;
                // 等级设为30
                *(int16_t*)(p + ESD_LV) = 30;

                // 验证修改 - 读回来确认
                uint64_t verifyData = *(uint64_t*)(p + ESD_DATA);
                uint64_t verifyTime = *(uint64_t*)(p + ESD_LASTTRIGGERTIME);
                int16_t verifyLv = *(int16_t*)(p + ESD_LV);

                jlog(@"fillAnger: ESD[%d] MODIFIED id=%d → anger=0x%llx(verify) cd=0x%llx lv=%d %s",
                     i, id, verifyData, verifyTime, verifyLv,
                     verifyData == newAnger ? "✓OK" : "✗MISMATCH!");
            } else {
                jlog(@"fillAnger: ESD[%d] id=0, skip", i);
            }
        }

        // 额外：hex dump第一个ExSkillData修改后的内容
        if (count > 0) {
            uint8_t *p0 = exDataArray;
            jlog(@"fillAnger: ESD[0] hex after mod: %02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x",
                 p0[0],p0[1],p0[2],p0[3], p0[4],p0[5],p0[6],p0[7],
                 p0[8],p0[9],p0[10],p0[11], p0[12],p0[13],p0[14],p0[15],
                 p0[16],p0[17],p0[18],p0[19], p0[20],p0[21],p0[22],p0[23],
                 p0[24],p0[25],p0[26],p0[27], p0[28],p0[29],p0[30],p0[31]);
        }
    } else {
        jlog(@"fillAnger: stride=0x%x != ESD_SIZE=0x%x, unexpected!", stride, ESD_SIZE);
    }
}

// ============================================================
// Hook函数实现
// ============================================================

static int g_unlockLogCount = 0;
static BOOL hookCheckSkillUnlock(void *self, int a1, int a2) {
    if (g_ignoreUnlock) {
        if (g_unlockLogCount < 10) { g_unlockLogCount++; jlog(@"Unlock[%d]: stateType=%d", g_unlockLogCount, a2); }
        return YES;
    }
    if (g_origCheckSkillUnlock) return g_origCheckSkillUnlock(self, a1, a2);
    return YES;
}

static int g_canUseLogCount = 0;
static BOOL hookCanUseExSkill(void *self, int a1, int a2) {
    if (g_exSkillAvail) {
        if (g_canUseLogCount < 10) { g_canUseLogCount++; jlog(@"CanUseExSkill[%d]", g_canUseLogCount); }
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
        jlog(@"TryTrigger[%d] type=%llu f=%p char=%p asset=%p noCD=%d",
             g_tryTriggerLogCount, type, f, character, asset, g_exSkillNoCD);
    }

    if (g_exSkillNoCD && character && f) {
        fillExSkillAnger(f, character);
    }

    // 调原函数
    BOOL result = NO;
    if (g_origTryTriggerExSkill) {
        result = g_origTryTriggerExSkill(f, type, trigger, fuse, targets, character, asset, triggerData);
    }

    // 记录原函数返回值 - 这很关键！
    static int resultLogCount = 0;
    if (resultLogCount < 30) {
        resultLogCount++;
        jlog(@"TryTrigger[%d] result=%d (YES=triggered, NO=not triggered)", resultLogCount, result);
    }

    return result;
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

    BOOL result = NO;
    if (g_origTriggerExSkillOrAdd) {
        result = g_origTriggerExSkillOrAdd(f, trigger, character, now, info, asset, lv);
    }

    static int orAddResultCount = 0;
    if (orAddResultCount < 30) {
        orAddResultCount++;
        jlog(@"OrAdd[%d] result=%d", orAddResultCount, result);
    }

    return result;
}

static int hookLimitDmg(void *self) { return g_damageLimit; }

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
    jlog(@"=== v20.0 IL2CPP Runtime Search ===");
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

    int found = 0, totalMethods = 0;
    for (size_t a = 0; a < assemCount; a++) {
        void *img = get_image(assemblies[a]); if (!img) continue;
        size_t cnt = class_count ? class_count(img) : 0;
        for (size_t c = 0; c < cnt; c++) {
            void *klass = get_class(img, c); if (!klass) continue;
            const char *cn = class_name_func ? class_name_func(klass) : NULL;
            void *iter = NULL, *m = NULL;
            while ((m = get_methods(klass, &iter)) != NULL) {
                totalMethods++;
                const char *n = method_name(m); if (!n) continue;
                uint32_t pc = param_count ? param_count(m) : 0;
                void *funcAddr = NULL; memcpy(&funcAddr, m, sizeof(void*));
                if (strcmp(n, "CheckSkillUnlock") == 0 && !g_funcCheckSkillUnlock) { jlog(@"FOUND %s.%s params=%u addr=%p", cn?:"?",n,pc,funcAddr); g_funcCheckSkillUnlock=funcAddr; found++; }
                else if (strcmp(n, "CanUseExSkill") == 0 && !g_funcCanUseExSkill) { jlog(@"FOUND %s.%s params=%u addr=%p", cn?:"?",n,pc,funcAddr); g_funcCanUseExSkill=funcAddr; found++; }
                else if (strcmp(n, "TryTriggerExSkill") == 0 && !g_funcTryTriggerExSkill) { jlog(@"FOUND %s.%s params=%u addr=%p", cn?:"?",n,pc,funcAddr); g_funcTryTriggerExSkill=funcAddr; found++; }
                else if (strcmp(n, "TriggerExSkillOrAdd") == 0 && !g_funcTriggerExSkillOrAdd) { jlog(@"FOUND %s.%s params=%u addr=%p", cn?:"?",n,pc,funcAddr); g_funcTriggerExSkillOrAdd=funcAddr; found++; }
                else if (strcmp(n, "get_limitDamage") == 0 && !g_funcLimitDmg) { jlog(@"FOUND %s.%s params=%u addr=%p", cn?:"?",n,pc,funcAddr); g_funcLimitDmg=funcAddr; found++; }
                else if (strcmp(n, "get_ExSkillDatas") == 0 && !g_funcGetExSkillDatas) { jlog(@"FOUND %s.%s params=%u addr=%p", cn?:"?",n,pc,funcAddr); g_funcGetExSkillDatas=(GetExSkillDatasFunc)funcAddr; found++; }
                else if (strcmp(n, "ResolveList") == 0 && !g_funcResolveList && cn && strcmp(cn, "FrameBase") == 0) { jlog(@"FOUND %s.%s params=%u addr=%p", cn?:"?",n,pc,funcAddr); g_funcResolveList=(ResolveListFunc)funcAddr; found++; }
            }
        }
    }
    jlog(@"Scanned %d methods, found %d targets", totalMethods, found);
    jlog(@"Unlock=%p CanUse=%p LimitDmg=%p TryTrigger=%p OrAdd=%p GetExData=%p ResolveList=%p",
         g_funcCheckSkillUnlock, g_funcCanUseExSkill, g_funcLimitDmg, g_funcTryTriggerExSkill, g_funcTriggerExSkillOrAdd, (void*)g_funcGetExSkillDatas, (void*)g_funcResolveList);
}

static void hookOneFunc(void *funcAddr, void *hookFunc, void **origFunc, BOOL *hookedFlag, const char *name) {
    if (!funcAddr) { jlog(@"%s: not found", name); return; }
    if (*hookedFlag) { jlog(@"%s: already hooked", name); return; }
    int ret = DobbyHook(funcAddr, hookFunc, origFunc);
    if (ret == 0) { *hookedFlag = YES; jlog(@"%s: OK at %p orig=%p", name, funcAddr, *origFunc); }
    else { jlog(@"%s: FAILED ret=%d", name, ret); }
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
    if (g_ignoreUnlock && !g_skillUnlockHooked) { findIL2CPP(); hookOneFunc(g_funcCheckSkillUnlock, hookCheckSkillUnlock, (void**)&g_origCheckSkillUnlock, &g_skillUnlockHooked, "1.忽略解锁"); }
    refreshButtons(); jlog(@"Toggle 忽略解锁: %d", g_ignoreUnlock);
}
- (void)onExSkillAvail {
    g_exSkillAvail=!g_exSkillAvail;
    if (g_exSkillAvail && !g_canUseExSkillHooked) { findIL2CPP(); hookOneFunc(g_funcCanUseExSkill, hookCanUseExSkill, (void**)&g_origCanUseExSkill, &g_canUseExSkillHooked, "2.大招可用"); }
    refreshButtons(); jlog(@"Toggle 大招可用: %d", g_exSkillAvail);
}
- (void)onExSkillNoCD {
    g_exSkillNoCD=!g_exSkillNoCD;
    if (g_exSkillNoCD) {
        findIL2CPP();
        if (!g_tryTriggerHooked) hookOneFunc(g_funcTryTriggerExSkill, hookTryTriggerExSkill, (void**)&g_origTryTriggerExSkill, &g_tryTriggerHooked, "4a.TryTrigger");
        if (!g_triggerOrAddHooked) hookOneFunc(g_funcTriggerExSkillOrAdd, hookTriggerExSkillOrAdd, (void**)&g_origTriggerExSkillOrAdd, &g_triggerOrAddHooked, "4b.OrAdd");
    }
    refreshButtons(); jlog(@"Toggle 大招无CD: %d TryTrigger=%d OrAdd=%d", g_exSkillNoCD, g_tryTriggerHooked, g_triggerOrAddHooked);
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
            if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *w in ((UIWindowScene *)scene).windows) { if (w.isKeyWindow && !w.isHidden) return w; }
                for (UIWindow *w in ((UIWindowScene *)scene).windows) { if (!w.isHidden) return w; }
            }
        }
    }
    for (UIWindow *w in [UIApplication sharedApplication].windows) { if (w.isKeyWindow && !w.isHidden) return w; }
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
    title.text=@"\u5251\u5f71\u6c5f\u6e56 v20.0"; title.textColor=[UIColor cyanColor];
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

__attribute__((constructor))
static void initialize(void) {
    static BOOL loaded = NO;
    if (loaded) return;
    loaded = YES;
    jlog(@"========== JYJH v20.0 (去掉id限制!) ==========");
    jlog(@"iOS %@", [[UIDevice currentDevice] systemVersion]);
    jlog(@"v20关键修复: 去掉id<100000限制, 修改所有ExSkillData!");
    jlog(@"v19发现: ExSkill[0] id=10020501被跳过了, 它可能就是关键的那个!");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(5.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        jlog(@"5s delay done");
        applyAllHooks();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ setupUI(); });
    });
}
