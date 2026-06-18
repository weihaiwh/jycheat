/**
 * 剑影江湖 v41.0 - 真全屏秒杀(Damage主动调用) + 皮肤修改(Hook UpdatePart)
 *
 * v40问题:
 *   1. IsFirstEnemyHit Hook安装成功但从未被调用
 *   2. 皮肤滑块只改了变量没写内存
 *
 * v41方案:
 *   全屏秒杀: 当玩家攻击时(Damage Hook), 对所有已知敌人CF也主动调用Damage
 *     - 通过CanBeAttack/AttackCanUse Hook收集所有敌人CF+EntityRef
 *     - 玩家攻击命中1个敌人时, 对其他敌人也调用Damage
 *   皮肤修改: Hook LobbyActorData.UpdatePart(skinId, weaponId, haloId)
 *     - 替换skinId参数→视觉换皮肤
 */

#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <dispatch/dispatch.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
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
static BOOL g_exSkillNoCD = NO;
static BOOL g_godMode = NO;
static BOOL g_fullScreen = NO;
static int g_damageLimit = 100;
static int g_skinId = 0;
static int g_weaponId = 0;

typedef BOOL (*BoolFunc3)(void*, int, int);
typedef int  (*IntFunc1)(void*);
typedef BOOL (*BoolFunc4)(void*, int, void*, void*);
typedef BOOL (*CanBeAttackFunc)(void*);
typedef int64_t (*DamageFunc)(void*, void*, void*, void*, void*, int32_t, int32_t, BOOL, int32_t, int32_t, void*, void*);
typedef int64_t (*DecreaseHPFunc)(void*, void*, void*, void*, int64_t);
typedef BOOL (*IntersectsFunc)(void *self, void *other);
typedef int32_t (*CheckHitFunc)(void *frame, void *collBound);
// UpdatePart(self, int skinId, int weaponId, int haloId)
typedef void (*UpdatePartFunc)(void*, int32_t, int32_t, int32_t);

static void *g_funcCheckSkillUnlock = NULL; static BoolFunc3 g_origCheckSkillUnlock = NULL; static BOOL g_skillUnlockHooked = NO;
static void *g_funcLimitDmg = NULL;         static IntFunc1 g_origLimitDmg = NULL;          static BOOL g_limitHooked = NO;
static void *g_funcCheckSkillIsReady = NULL; static BoolFunc4 g_origCheckSkillIsReady = NULL; static BOOL g_isReadyHooked = NO;
static void *g_funcCheckSkillAttackCanUse = NULL; static BoolFunc4 g_origCheckSkillAttackCanUse = NULL; static BOOL g_attackCanUseHooked = NO;
static void *g_funcCanBeAttack = NULL;      static CanBeAttackFunc g_origCanBeAttack = NULL; static BOOL g_canBeAttackHooked = NO;
static void *g_funcDamage = NULL;           static DamageFunc g_origDamage = NULL;           static BOOL g_damageHooked = NO;
static void *g_funcDecreaseHP = NULL;       static DecreaseHPFunc g_origDecreaseHP = NULL;   static BOOL g_decreaseHPRooked = NO;
static void *g_funcIntersects = NULL;       static IntersectsFunc g_origIntersects = NULL;   static BOOL g_intersectsHooked = NO;
static void *g_funcCheckHit = NULL;         static CheckHitFunc g_origCheckHit = NULL;        static BOOL g_checkHitHooked = NO;
static void *g_funcUpdatePart = NULL;       static UpdatePartFunc g_origUpdatePart = NULL;   static BOOL g_updatePartHooked = NO;

static void *g_playerCF = NULL;
static void *g_playerEntity = NULL;
static BOOL g_playerCFLearned = NO;

// 敌人追踪: 收集所有非玩家CF和对应EntityRef
#define MAX_ENEMIES 64
static void *g_enemyCFs[MAX_ENEMIES];
static void *g_enemyEntities[MAX_ENEMIES];
static int g_enemyCount = 0;

static BOOL isPlayerCF(void *cf) {
    if (!cf) return NO;
    int32_t isAI = -1;
    memcpy(&isAI, (uint8_t*)cf + 0x44, 4);
    return (isAI == 0);
}

static BOOL isDeadCF(void *cf) {
    if (!cf) return YES;
    int32_t isDead = -1;
    memcpy(&isDead, (uint8_t*)cf + 0x48, 4);
    return (isDead != 0);
}

static void trackEnemy(void *cf, void *entity) {
    if (!cf || !entity || isPlayerCF(cf)) return;
    // 检查是否已追踪
    for (int i = 0; i < g_enemyCount; i++) {
        if (g_enemyCFs[i] == cf) {
            g_enemyEntities[i] = entity; // 更新entity
            return;
        }
    }
    // 添加新敌人
    if (g_enemyCount < MAX_ENEMIES) {
        g_enemyCFs[g_enemyCount] = cf;
        g_enemyEntities[g_enemyCount] = entity;
        g_enemyCount++;
    }
}

static int g_unlockLogCount = 0;
static BOOL hookCheckSkillUnlock(void *self, int a1, int a2) {
    if (g_ignoreUnlock) {
        if (g_unlockLogCount < 5) { g_unlockLogCount++; jlog(@"Unlock[%d]: st=%d", g_unlockLogCount, a2); }
        return YES;
    }
    return g_origCheckSkillUnlock ? g_origCheckSkillUnlock(self, a1, a2) : YES;
}

static int g_isReadyLogCount = 0;
static int g_godModeLogCount = 0;
static BOOL hookCheckSkillIsReady(void *frame, int stateType, void *characterField, void *states) {
    if (characterField) {
        if (isPlayerCF(characterField)) {
            if (!g_playerCFLearned) {
                g_playerCF = characterField; g_playerCFLearned = YES;
                jlog(@"IsReady: PlayerCF=%p", characterField);
            }
        } else {
            // 追踪敌人
            trackEnemy(characterField, NULL);
        }
    }
    if (g_exSkillNoCD && stateType >= 17) {
        if (g_isReadyLogCount < 30) { g_isReadyLogCount++; jlog(@"IsReady[%d] st=%d->YES", g_isReadyLogCount, stateType); }
        return YES;
    }
    return g_origCheckSkillIsReady ? g_origCheckSkillIsReady(frame, stateType, characterField, states) : YES;
}

static int g_attackCanUseLogCount = 0;
static BOOL hookCheckSkillAttackCanUse(void *frame, int stateType, void *characterField, void *states) {
    if (characterField) {
        if (isPlayerCF(characterField) && !g_playerCFLearned) {
            g_playerCF = characterField; g_playerCFLearned = YES;
            jlog(@"AttackCanUse: PlayerCF=%p", characterField);
        }
    }
    if (g_exSkillNoCD && stateType >= 17) {
        if (g_attackCanUseLogCount < 30) { g_attackCanUseLogCount++; jlog(@"AttackCanUse[%d] st=%d->YES", g_attackCanUseLogCount, stateType); }
        return YES;
    }
    return g_origCheckSkillAttackCanUse ? g_origCheckSkillAttackCanUse(frame, stateType, characterField, states) : YES;
}

static int hookLimitDmg(void *self) { return g_damageLimit; }

static int g_canBeAttackLogCount = 0;
static BOOL hookCanBeAttack(void *cf) {
    if (cf) {
        if (isPlayerCF(cf)) {
            if (g_godMode) {
                if (g_canBeAttackLogCount < 20) { g_canBeAttackLogCount++; jlog(@"CanBeAttack[%d]: Player->NO", g_canBeAttackLogCount); }
                return NO;
            }
        } else {
            // 追踪敌人
            trackEnemy(cf, NULL);
        }
    }
    return g_origCanBeAttack ? g_origCanBeAttack(cf) : YES;
}

static int g_damageLogCount = 0;
static int g_fullScreenDmgCount = 0;
static int64_t hookDamage(void *f, void *atkEntity, void *atkCF, void *tgtEntity, void *tgtCF,
                          int32_t hitEffectId, int32_t hitSound, BOOL isRight,
                          int32_t skillButton, int32_t skillPart, void *hurtFlag, void *exSkills) {
    BOOL tgtIsPlayer = (tgtCF && isPlayerCF(tgtCF));
    BOOL atkIsPlayer = (atkCF && isPlayerCF(atkCF));

    // 记录玩家EntityRef
    if (atkIsPlayer && atkEntity) {
        g_playerEntity = atkEntity;
    }

    // 追踪被攻击的敌人
    if (tgtCF && !tgtIsPlayer && tgtEntity) {
        trackEnemy(tgtCF, tgtEntity);
    }

    // 不死: 玩家被攻击→返回0
    if (g_godMode && tgtIsPlayer) {
        if (g_damageLogCount < 20) { g_damageLogCount++; jlog(@"Damage[%d]: tgt=Player -> 0", g_damageLogCount); }
        return 0;
    }

    if (!g_origDamage) return 0;
    int64_t result = g_origDamage(f, atkEntity, atkCF, tgtEntity, tgtCF, hitEffectId, hitSound, isRight, skillButton, skillPart, hurtFlag, exSkills);

    if (atkIsPlayer && result > 0) {
        if (g_damageLogCount < 20) { g_damageLogCount++; jlog(@"Damage[%d]: atk=Player dmg=%lld tgt=%s", g_damageLogCount, result, tgtIsPlayer ? "Player" : "Enemy"); }

        // v41: 全屏秒杀 - 玩家攻击命中1个敌人时, 对其他已知敌人也调用Damage
        if (g_fullScreen && !tgtIsPlayer && g_playerEntity && g_enemyCount > 0) {
            for (int i = 0; i < g_enemyCount; i++) {
                void *eCF = g_enemyCFs[i];
                void *eEnt = g_enemyEntities[i];
                // 跳过: 已命中的目标、空指针、已死亡、玩家
                if (!eCF || eCF == tgtCF || isPlayerCF(eCF) || isDeadCF(eCF)) continue;
                if (!eEnt) continue;
                // 对该敌人调用Damage
                int64_t dmg = g_origDamage(f, g_playerEntity, atkCF, eEnt, eCF,
                                           hitEffectId, hitSound, isRight,
                                           skillButton, skillPart, hurtFlag, exSkills);
                if (dmg > 0 && g_fullScreenDmgCount < 30) {
                    g_fullScreenDmgCount++;
                    jlog(@"FullDmg[%d]: enemy cf=%p dmg=%lld", g_fullScreenDmgCount, eCF, dmg);
                }
            }
        }
    }
    return result;
}

static int g_intersectsLogCount = 0;
static BOOL hookIntersects(void *self, void *other) {
    if (g_fullScreen) {
        return YES;
    }
    return g_origIntersects ? g_origIntersects(self, other) : NO;
}

static int g_checkHitLogCount = 0;
static int32_t hookCheckHit(void *frame, void *collBound) {
    if (g_fullScreen) {
        return 1;
    }
    return g_origCheckHit ? g_origCheckHit(frame, collBound) : 0;
}

// v41: Hook UpdatePart - 修改皮肤参数
static int g_updatePartLogCount = 0;
static void hookUpdatePart(void *self, int32_t skinId, int32_t weaponId, int32_t haloId) {
    if (g_skinId > 0 || g_weaponId > 0) {
        int32_t newSkin = g_skinId > 0 ? g_skinId : skinId;
        int32_t newWeapon = g_weaponId > 0 ? g_weaponId : weaponId;
        if (g_updatePartLogCount < 10) {
            g_updatePartLogCount++;
            jlog(@"UpdatePart[%d]: skin %d->%d weapon %d->%d halo=%d", g_updatePartLogCount, skinId, newSkin, weaponId, newWeapon, haloId);
        }
        if (g_origUpdatePart) g_origUpdatePart(self, newSkin, newWeapon, haloId);
    } else {
        if (g_origUpdatePart) g_origUpdatePart(self, skinId, weaponId, haloId);
    }
}

// IL2CPP search
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
    jlog(@"=== v41.0 IL2CPP Search ===");
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
    void *domain = domain_get(); if (!domain) return;
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
                if (strcmp(n, "CheckSkillUnlock") == 0 && !g_funcCheckSkillUnlock) { g_funcCheckSkillUnlock=funcAddr; found++; jlog(@"FOUND %s.%s p=%u %p", cn?:"?",n,pc,funcAddr); }
                else if (strcmp(n, "get_limitDamage") == 0 && !g_funcLimitDmg) { g_funcLimitDmg=funcAddr; found++; jlog(@"FOUND %s.%s p=%u %p", cn?:"?",n,pc,funcAddr); }
                else if (strcmp(n, "CheckSkillIsReady") == 0 && !g_funcCheckSkillIsReady) { g_funcCheckSkillIsReady=funcAddr; found++; jlog(@"FOUND %s.%s p=%u %p", cn?:"?",n,pc,funcAddr); }
                else if (strcmp(n, "CheckSkillAttackCanUse") == 0 && !g_funcCheckSkillAttackCanUse) { g_funcCheckSkillAttackCanUse=funcAddr; found++; jlog(@"FOUND %s.%s p=%u %p", cn?:"?",n,pc,funcAddr); }
                else if (strcmp(n, "CanBeAttack") == 0 && !g_funcCanBeAttack) { g_funcCanBeAttack=funcAddr; found++; jlog(@"FOUND %s.%s p=%u %p", cn?:"?",n,pc,funcAddr); }
                else if (strcmp(n, "Damage") == 0 && pc >= 10 && !g_funcDamage) { g_funcDamage=funcAddr; found++; jlog(@"FOUND %s.%s p=%u %p", cn?:"?",n,pc,funcAddr); }
                else if (strcmp(n, "Intersects") == 0 && pc == 1 && cn && strstr(cn, "FPBounds2") != NULL && !g_funcIntersects) { g_funcIntersects=funcAddr; found++; jlog(@"FOUND %s.%s p=%u %p", cn?:"?",n,pc,funcAddr); }
                else if (strcmp(n, "CheckPlayerHitCollider") == 0 && pc == 2 && !g_funcCheckHit) { g_funcCheckHit=funcAddr; found++; jlog(@"FOUND %s.%s p=%u %p", cn?:"?",n,pc,funcAddr); }
                else if (strcmp(n, "UpdatePart") == 0 && pc == 3 && cn && strstr(cn, "LobbyActorData") != NULL && !g_funcUpdatePart) { g_funcUpdatePart=funcAddr; found++; jlog(@"FOUND %s.%s p=%u %p", cn?:"?",n,pc,funcAddr); }
            }
        }
    }
    jlog(@"Scanned %d methods, found %d targets", totalMethods, found);
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
    hookOneFunc(g_funcLimitDmg, hookLimitDmg, (void**)&g_origLimitDmg, &g_limitHooked, "limitDmg");
    jlog(@"applyAllHooks done");
}

// ===== ImGui-style UI =====

static UIView *g_panel = nil;
static UIButton *g_btnIgnoreUnlock = nil;
static UIButton *g_btnExSkillNoCD = nil;
static UIButton *g_btnGodMode = nil;
static UIButton *g_btnFullScreen = nil;
static UISlider *g_slider = nil;
static UILabel *g_sliderLabel = nil;
static UISlider *g_skinSlider = nil;
static UILabel *g_skinLabel = nil;
static UISlider *g_weaponSlider = nil;
static UILabel *g_weaponLabel = nil;
static BOOL g_panelOpen = NO;

// ImGui color palette
#define IMGUI_BG         [UIColor colorWithRed:0.09 green:0.09 blue:0.12 alpha:0.96]
#define IMGUI_TITLE_BG   [UIColor colorWithRed:0.04 green:0.04 blue:0.06 alpha:1.0]
#define IMGUI_ACCENT     [UIColor colorWithRed:0.40 green:0.68 blue:1.00 alpha:1.0]
#define IMGUI_GREEN      [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0]
#define IMGUI_RED        [UIColor colorWithRed:0.78 green:0.20 blue:0.20 alpha:1.0]
#define IMGUI_TEXT       [UIColor colorWithRed:0.90 green:0.90 blue:0.92 alpha:1.0]
#define IMGUI_DIMTEXT    [UIColor colorWithRed:0.55 green:0.55 blue:0.60 alpha:1.0]
#define IMGUI_BALL_BG    [UIColor colorWithRed:0.12 green:0.28 blue:0.58 alpha:0.92]
#define IMGUI_BTN_ON     [UIColor colorWithRed:0.16 green:0.52 blue:0.28 alpha:0.95]
#define IMGUI_BTN_OFF    [UIColor colorWithRed:0.52 green:0.14 blue:0.14 alpha:0.95]
#define IMGUI_BORDER     [UIColor colorWithRed:0.25 green:0.25 blue:0.30 alpha:0.8]

// Forward declare
@interface JYJHActionHandler : NSObject
+ (instancetype)shared;
- (void)onIgnoreUnlock;
- (void)onExSkillNoCD;
- (void)onGodMode;
- (void)onFullScreen;
- (void)sliderChanged:(UISlider *)slider;
- (void)skinSliderChanged:(UISlider *)slider;
- (void)weaponSliderChanged:(UISlider *)slider;
@end

static UIButton* makeImguiBtn(CGRect frame, SEL action) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = frame;
    b.layer.cornerRadius = 4;
    b.layer.borderWidth = 1;
    b.layer.borderColor = IMGUI_BORDER.CGColor;
    UIFont *btnFont = [UIFont boldSystemFontOfSize:12];
    b.titleLabel.font = btnFont;
    b.titleLabel.textColor = IMGUI_TEXT;
    [b addTarget:[JYJHActionHandler shared] action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

static void refreshButtons(void) {
    if (g_ignoreUnlock) {
        [g_btnIgnoreUnlock setTitle:@"ON  \xe5\xbf\xbd\xe7\x95\xa5\xe8\xa7\xa3\xe9\x94\x81" forState:UIControlStateNormal];
        g_btnIgnoreUnlock.backgroundColor = IMGUI_BTN_ON;
        g_btnIgnoreUnlock.layer.borderColor = IMGUI_GREEN.CGColor;
    } else {
        [g_btnIgnoreUnlock setTitle:@"OFF \xe5\xbf\xbd\xe7\x95\xa5\xe8\xa7\xa3\xe9\x94\x81" forState:UIControlStateNormal];
        g_btnIgnoreUnlock.backgroundColor = IMGUI_BTN_OFF;
        g_btnIgnoreUnlock.layer.borderColor = IMGUI_RED.CGColor;
    }
    if (g_exSkillNoCD) {
        [g_btnExSkillNoCD setTitle:@"ON  \xe6\x8a\x80\xe8\x83\xbd\xe6\x97" "\xa0" "CD" forState:UIControlStateNormal];
        g_btnExSkillNoCD.backgroundColor = IMGUI_BTN_ON;
        g_btnExSkillNoCD.layer.borderColor = IMGUI_GREEN.CGColor;
    } else {
        [g_btnExSkillNoCD setTitle:@"OFF \xe6\x8a\x80\xe8\x83\xbd\xe6\x97" "\xa0" "CD" forState:UIControlStateNormal];
        g_btnExSkillNoCD.backgroundColor = IMGUI_BTN_OFF;
        g_btnExSkillNoCD.layer.borderColor = IMGUI_RED.CGColor;
    }
    if (g_godMode) {
        [g_btnGodMode setTitle:@"ON  \xe7\x8e\xa9\xe5\xae\xb6\xe4\xb8\x8d\xe6\xad\xbb" forState:UIControlStateNormal];
        g_btnGodMode.backgroundColor = IMGUI_BTN_ON;
        g_btnGodMode.layer.borderColor = IMGUI_GREEN.CGColor;
    } else {
        [g_btnGodMode setTitle:@"OFF \xe7\x8e\xa9\xe5\xae\xb6\xe4\xb8\x8d\xe6\xad\xbb" forState:UIControlStateNormal];
        g_btnGodMode.backgroundColor = IMGUI_BTN_OFF;
        g_btnGodMode.layer.borderColor = IMGUI_RED.CGColor;
    }
    if (g_fullScreen) {
        [g_btnFullScreen setTitle:@"ON  \xe5\x85\xa8\xe5\xb1\x8f\xe7\xa7\x92\xe6\x9d\x80" forState:UIControlStateNormal];
        g_btnFullScreen.backgroundColor = IMGUI_BTN_ON;
        g_btnFullScreen.layer.borderColor = IMGUI_GREEN.CGColor;
    } else {
        [g_btnFullScreen setTitle:@"OFF \xe5\x85\xa8\xe5\xb1\x8f\xe7\xa7\x92\xe6\x9d\x80" forState:UIControlStateNormal];
        g_btnFullScreen.backgroundColor = IMGUI_BTN_OFF;
        g_btnFullScreen.layer.borderColor = IMGUI_RED.CGColor;
    }
}

static void layoutPanel(UIView *bv) {
    if (!bv || !g_panel) return;
    CGRect bf=bv.frame, sc=[UIScreen mainScreen].bounds;
    CGFloat pw=240, ph=440;
    CGFloat px=bf.origin.x-pw-6; if(px<4)px=bf.origin.x+bf.size.width+6;
    CGFloat py=bf.origin.y+bf.size.height/2-ph/2;
    if(py<4)py=4; if(py+ph>sc.size.height-4)py=sc.size.height-ph-4;
    g_panel.frame=CGRectMake(px,py,pw,ph);
}

static void togglePanel(UIView *bv) {
    g_panelOpen=!g_panelOpen; g_panel.hidden=!g_panelOpen;
    if(g_panelOpen)layoutPanel(bv);
}

@implementation JYJHActionHandler
+ (instancetype)shared { static JYJHActionHandler *s; static dispatch_once_t o; dispatch_once(&o,^{s=[[self alloc]init];}); return s; }
- (void)onIgnoreUnlock {
    g_ignoreUnlock=!g_ignoreUnlock;
    if (g_ignoreUnlock && !g_skillUnlockHooked) { findIL2CPP(); hookOneFunc(g_funcCheckSkillUnlock, hookCheckSkillUnlock, (void**)&g_origCheckSkillUnlock, &g_skillUnlockHooked, "Unlock"); }
    refreshButtons(); jlog(@"Toggle Unlock: %d", g_ignoreUnlock);
}
- (void)onExSkillNoCD {
    g_exSkillNoCD=!g_exSkillNoCD;
    if (g_exSkillNoCD) {
        findIL2CPP();
        if (!g_isReadyHooked) hookOneFunc(g_funcCheckSkillIsReady, hookCheckSkillIsReady, (void**)&g_origCheckSkillIsReady, &g_isReadyHooked, "IsReady");
        if (!g_attackCanUseHooked) hookOneFunc(g_funcCheckSkillAttackCanUse, hookCheckSkillAttackCanUse, (void**)&g_origCheckSkillAttackCanUse, &g_attackCanUseHooked, "AttackCanUse");
    }
    refreshButtons(); jlog(@"Toggle NoCD: %d", g_exSkillNoCD);
}
- (void)onGodMode {
    g_godMode=!g_godMode;
    if (g_godMode) {
        findIL2CPP();
        if (!g_attackCanUseHooked) hookOneFunc(g_funcCheckSkillAttackCanUse, hookCheckSkillAttackCanUse, (void**)&g_origCheckSkillAttackCanUse, &g_attackCanUseHooked, "AttackCanUse");
        if (!g_isReadyHooked) hookOneFunc(g_funcCheckSkillIsReady, hookCheckSkillIsReady, (void**)&g_origCheckSkillIsReady, &g_isReadyHooked, "IsReady");
        if (!g_canBeAttackHooked) hookOneFunc(g_funcCanBeAttack, hookCanBeAttack, (void**)&g_origCanBeAttack, &g_canBeAttackHooked, "CanBeAttack");
        if (!g_damageHooked) hookOneFunc(g_funcDamage, hookDamage, (void**)&g_origDamage, &g_damageHooked, "Damage");
    }
    refreshButtons(); jlog(@"Toggle God: %d", g_godMode);
}
- (void)onFullScreen {
    g_fullScreen=!g_fullScreen;
    if (g_fullScreen) {
        findIL2CPP();
        if (!g_intersectsHooked) hookOneFunc(g_funcIntersects, hookIntersects, (void**)&g_origIntersects, &g_intersectsHooked, "Intersects");
        if (!g_checkHitHooked) hookOneFunc(g_funcCheckHit, hookCheckHit, (void**)&g_origCheckHit, &g_checkHitHooked, "CheckHit(Z)");
        if (!g_damageHooked) hookOneFunc(g_funcDamage, hookDamage, (void**)&g_origDamage, &g_damageHooked, "Damage");
        // 清空敌人列表重新收集
        g_enemyCount = 0;
        g_fullScreenDmgCount = 0;
        jlog(@"FullScreen ON: will spread damage to all enemies");
    } else {
        jlog(@"FullScreen OFF");
    }
    refreshButtons();
}
- (void)sliderChanged:(UISlider *)s {
    g_damageLimit=(int)s.value;
    g_sliderLabel.text=[NSString stringWithFormat:@"\xe4\xbc\xa4\xe5\xae\xb3\xe4\xb8\x8a\xe9\x99\x90: %d",g_damageLimit];
}
- (void)skinSliderChanged:(UISlider *)s {
    g_skinId=(int)s.value;
    g_skinLabel.text=[NSString stringWithFormat:@"\xe7\x9a\xae\xe8\x82\xa4" "ID: %d", g_skinId];
    if (g_skinId > 0) {
        findIL2CPP();
        if (!g_updatePartHooked && g_funcUpdatePart) {
            hookOneFunc(g_funcUpdatePart, hookUpdatePart, (void**)&g_origUpdatePart, &g_updatePartHooked, "UpdatePart");
        }
        jlog(@"SkinID=%d (need re-enter lobby to see)", g_skinId);
    }
}
- (void)weaponSliderChanged:(UISlider *)s {
    g_weaponId=(int)s.value;
    g_weaponLabel.text=[NSString stringWithFormat:@"\xe6\xad\xa6\xe5\x99\xa8" "ID: %d", g_weaponId];
    if (g_weaponId > 0) {
        findIL2CPP();
        if (!g_updatePartHooked && g_funcUpdatePart) {
            hookOneFunc(g_funcUpdatePart, hookUpdatePart, (void**)&g_origUpdatePart, &g_updatePartHooked, "UpdatePart");
        }
        jlog(@"WeaponID=%d", g_weaponId);
    }
}
@end

// Floating ball - ImGui style
@interface JYJHBallView : UIView { CGPoint _ts; BOOL _drag; }
@end
@implementation JYJHBallView
- (instancetype)init {
    self=[super initWithFrame:CGRectMake([UIScreen mainScreen].bounds.size.width-42,120,36,36)];
    if(self){
    self.backgroundColor=IMGUI_BALL_BG;
    self.layer.cornerRadius=18;
    self.layer.borderWidth=1.5;
    self.layer.borderColor=IMGUI_ACCENT.CGColor;
    self.userInteractionEnabled=YES;
    UILabel*l=[[UILabel alloc]initWithFrame:CGRectMake(0,0,36,36)];
    l.text=@"\xe5\x89\x91"; l.textColor=[UIColor whiteColor];
    l.font=[UIFont boldSystemFontOfSize:16]; l.textAlignment=NSTextAlignmentCenter;
    [self addSubview:l];
    }
    return self;
}
- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent*)e{return CGRectContainsPoint(CGRectInset(self.bounds,-6,-6),p);}
- (void)touchesBegan:(NSSet*)t withEvent:(UIEvent*)e{_ts=[[t anyObject]locationInView:self.superview];_drag=NO;}
- (void)touchesMoved:(NSSet*)t withEvent:(UIEvent*)e{CGPoint c=[[t anyObject]locationInView:self.superview];CGFloat dx=c.x-_ts.x,dy=c.y-_ts.y;if(fabs(dx)>5||fabs(dy)>5){_drag=YES;CGRect f=self.frame;CGRect sc=[UIScreen mainScreen].bounds;f.origin.x=MAX(0,MIN(sc.size.width-f.size.width,f.origin.x+dx));f.origin.y=MAX(50,MIN(sc.size.height-f.size.height-50,f.origin.y+dy));self.frame=f;_ts=c;if(g_panelOpen)layoutPanel(self);}}
- (void)touchesEnded:(NSSet*)t withEvent:(UIEvent*)e{if(!_drag)togglePanel(self);_drag=NO;}
- (void)touchesCancelled:(NSSet*)t withEvent:(UIEvent*)e{_drag=NO;}
@end

static UIWindow *getKeyWindow(void) {
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (!w.isHidden) return w;
    }
    return nil;
}

static void setupUI(void) {
    UIWindow *win = getKeyWindow();
    if (!win) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{setupUI();}); return; }
    JYJHBallView *ball = [[JYJHBallView alloc] init]; [win addSubview:ball];

    CGFloat pw=240, ph=440;
    g_panel=[[UIView alloc]initWithFrame:CGRectMake(0,0,pw,ph)];
    g_panel.backgroundColor=IMGUI_BG;
    g_panel.layer.cornerRadius=8;
    g_panel.layer.borderWidth=1;
    g_panel.layer.borderColor=IMGUI_BORDER.CGColor;
    g_panel.hidden=YES;
    g_panel.clipsToBounds=YES;
    [win addSubview:g_panel];

    // Title bar
    UIView *titleBar=[[UIView alloc]initWithFrame:CGRectMake(0,0,pw,28)];
    titleBar.backgroundColor=IMGUI_TITLE_BG;
    [g_panel addSubview:titleBar];

    UILabel *title=[[UILabel alloc]initWithFrame:CGRectMake(8,4,pw-16,20)];
    title.text=@"  \xe5\x89\x91\xe5\xbd\xb1\xe6\xb1\x9f\xe6\xb9\x96 v41.0"; title.textColor=IMGUI_ACCENT;
    title.font=[UIFont boldSystemFontOfSize:13];
    title.textAlignment=NSTextAlignmentLeft; [titleBar addSubview:title];

    // Buttons - ImGui toggle style
    CGFloat bx=10, bw=pw-20, bh=30, by0=36, bdy=34;
    g_btnIgnoreUnlock=makeImguiBtn(CGRectMake(bx,by0,bw,bh), @selector(onIgnoreUnlock)); [g_panel addSubview:g_btnIgnoreUnlock];
    g_btnExSkillNoCD=makeImguiBtn(CGRectMake(bx,by0+bdy,bw,bh), @selector(onExSkillNoCD)); [g_panel addSubview:g_btnExSkillNoCD];
    g_btnGodMode=makeImguiBtn(CGRectMake(bx,by0+bdy*2,bw,bh), @selector(onGodMode)); [g_panel addSubview:g_btnGodMode];
    g_btnFullScreen=makeImguiBtn(CGRectMake(bx,by0+bdy*3,bw,bh), @selector(onFullScreen)); [g_panel addSubview:g_btnFullScreen];

    // Separator 1
    CGFloat sep1Y = by0 + bdy*4 - 2;
    UIView *sep1=[[UIView alloc]initWithFrame:CGRectMake(bx,sep1Y,bw,1)];
    sep1.backgroundColor=IMGUI_BORDER; [g_panel addSubview:sep1];

    // Damage slider
    CGFloat sy = sep1Y + 6;
    g_sliderLabel=[[UILabel alloc]initWithFrame:CGRectMake(bx,sy,bw,16)];
    g_sliderLabel.text=[NSString stringWithFormat:@"\xe4\xbc\xa4\xe5\xae\xb3\xe4\xb8\x8a\xe9\x99\x90: %d", g_damageLimit];
    g_sliderLabel.textColor=IMGUI_DIMTEXT;
    g_sliderLabel.font=[UIFont systemFontOfSize:11];
    [g_panel addSubview:g_sliderLabel];

    g_slider=[[UISlider alloc]initWithFrame:CGRectMake(bx,sy+18,bw,24)];
    g_slider.minimumValue=1; g_slider.maximumValue=5000; g_slider.value=g_damageLimit;
    [g_slider addTarget:[JYJHActionHandler shared] action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [g_panel addSubview:g_slider];

    // Separator 2
    CGFloat sep2Y = sy + 48;
    UIView *sep2=[[UIView alloc]initWithFrame:CGRectMake(bx,sep2Y,bw,1)];
    sep2.backgroundColor=IMGUI_BORDER; [g_panel addSubview:sep2];

    // Skin section
    CGFloat ssy = sep2Y + 4;
    UILabel *secTitle=[[UILabel alloc]initWithFrame:CGRectMake(bx,ssy,bw,16)];
    secTitle.text=@"\xe7\x9a\xae\xe8\x82\xa4/\xe6\xad\xa6\xe5\x99\xa8" " (\xe4\xbb\x85\xe8\xa7\x86\xe8\xa7\x89 \xe9\x9c\x80\xe9\x87\x8d\xe8\xbf\x9b\xe5\xa4\xa7\xe5\x8e\x85)";
    secTitle.textColor=IMGUI_ACCENT;
    secTitle.font=[UIFont boldSystemFontOfSize:10];
    [g_panel addSubview:secTitle];

    // Skin slider
    g_skinLabel=[[UILabel alloc]initWithFrame:CGRectMake(bx,ssy+16,bw,16)];
    g_skinLabel.text=[NSString stringWithFormat:@"\xe7\x9a\xae\xe8\x82\xa4" "ID: %d", g_skinId];
    g_skinLabel.textColor=IMGUI_DIMTEXT;
    g_skinLabel.font=[UIFont systemFontOfSize:11];
    [g_panel addSubview:g_skinLabel];

    g_skinSlider=[[UISlider alloc]initWithFrame:CGRectMake(bx,ssy+32,bw,24)];
    g_skinSlider.minimumValue=0; g_skinSlider.maximumValue=200; g_skinSlider.value=g_skinId;
    [g_skinSlider addTarget:[JYJHActionHandler shared] action:@selector(skinSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [g_panel addSubview:g_skinSlider];

    // Weapon slider
    g_weaponLabel=[[UILabel alloc]initWithFrame:CGRectMake(bx,ssy+58,bw,16)];
    g_weaponLabel.text=[NSString stringWithFormat:@"\xe6\xad\xa6\xe5\x99\xa8" "ID: %d", g_weaponId];
    g_weaponLabel.textColor=IMGUI_DIMTEXT;
    g_weaponLabel.font=[UIFont systemFontOfSize:11];
    [g_panel addSubview:g_weaponLabel];

    g_weaponSlider=[[UISlider alloc]initWithFrame:CGRectMake(bx,ssy+74,bw,24)];
    g_weaponSlider.minimumValue=0; g_weaponSlider.maximumValue=200; g_weaponSlider.value=g_weaponId;
    [g_weaponSlider addTarget:[JYJHActionHandler shared] action:@selector(weaponSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [g_panel addSubview:g_weaponSlider];

    refreshButtons();
}

__attribute__((constructor))
static void initialize(void) {
    static BOOL loaded = NO;
    if (loaded) return;
    loaded = YES;
    jlog(@"========== JYJH v41.0 ==========");
    jlog(@"iOS %@", [[UIDevice currentDevice] systemVersion]);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(5.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        jlog(@"5s delay done");
        applyAllHooks();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ setupUI(); });
    });
}
