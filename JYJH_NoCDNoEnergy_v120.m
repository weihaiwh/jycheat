/**
 * v120 - 修复怪不动影响玩家 + 修复全屏秒杀卡死
 * v119问题:
 *   1. hook AISystem.Update跳过整个AI系统 → 玩家也受影响不动了！
 *      玩家的自动战斗也是AI系统驱动的, 跳过整个系统玩家也无法行动
 *   2. 全屏秒杀+玩家不死 → 怪死前游戏卡死
 *      根因: 全屏秒杀的HitSystem.Update用INT64_MAX扩大范围 → FPBounds2.Intersects
 *      返回YES但FP计算溢出, 导致后续距离/方向计算死循环
 * v120核心改动:
 *   1. 怪不动: 不再hook AISystem.Update — 改为hook AIAgent.Update(ref AIParams& Params)
 *      在hook中读取AIParams._entity, 通过EntityRef获取CharacterFiled, 判断Camp
 *      Camp=0是玩家(不冻结), Camp≠0是敌方(跳过Update → 不动+不攻击)
 *      AIParams结构(值类型, 含0x10伪header):
 *        _frame @ 0x10, _agent* @ 0x18, _entity @ 0x20(EntityRef=8字节Raw), _states @ 0x28, _root @ 0x30
 *      EntityRef.Raw @ offset 0x10 → 实际偏移 = 0x20-0x10+0x10 = 0x20 (Raw是第一个字段)
 *      但值类型偏移不需要减0x10! AIParams._entity实际在 struct+0x20 处
 *   2. 全屏秒杀修复: 不再用INT64_MAX, 改用0x100000000(65536.0 in FP)作为超大范围
 *      避免FP算术溢出导致的死循环
 * 关键dump偏移:
 *   AIAgent.Update(ref AIParams& Params) @ 0x30682cc — 实例方法, 1参数
 *   AIParams: _frame@0x10, _agent*@0x18, _entity@0x20(Raw=8字节), _states@0x28, _root@0x30
 *   CharacterFiled.Camp @ cf+0x24: 0=玩家, 非0=敌方
 */
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <dispatch/dispatch.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <stdio.h>
#import <string.h>
#import <dlfcn.h>
#include "substrate.h"
#import <objc/runtime.h>

static FILE *g_logFile = NULL;
static void jlog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void jlog(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[JYJH] %@", msg);
    if (!g_logFile) { NSString *p = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/jyjh.log"]; g_logFile = fopen([p UTF8String], "a"); }
    if (g_logFile) { fprintf(g_logFile, "%s\n", [msg UTF8String]); fflush(g_logFile); }
}

static BOOL g_ignoreUnlock=NO, g_exSkillNoCD=NO, g_godMode=NO, g_fullScreen=NO;
static BOOL g_skillReplace=NO;
static BOOL g_replaceSkill1=NO, g_replaceSkill2=NO, g_replaceSkill3=NO, g_replaceSkill4=NO, g_replaceSkill5=NO;
static int g_damageLimit=100, g_skinId=0, g_weaponId=0, g_haloId=0;
static int g_damageMulti=1;
static float g_speedMul=1.0f;
static BOOL g_vacuumMode=NO;
static BOOL g_antiReport=NO;
static BOOL g_noAds=NO; // v116: 免广告
static BOOL g_monsterFreeze=NO; // v118: 怪不动
static BOOL g_attackRangePlus=NO; // v118: 攻击范围+

typedef BOOL (*BoolFunc3)(void*,int,int);
typedef int (*IntFunc1)(void*);
typedef BOOL (*BoolFunc4)(void*,int,void*,void*);
typedef BOOL (*CanBeAttackFunc)(void*);
typedef int64_t (*DamageFunc)(void*,void*,void*,void*,void*,int32_t,int32_t,BOOL,int32_t,int32_t,void*,void*);
typedef int64_t (*DecreaseHPFunc)(void*,void*,void*,void*,int64_t);
typedef BOOL (*IntersectsFunc)(void*,void*);
typedef int32_t (*CheckHitFunc)(void*,void*);
typedef void (*UseSkillFunc)(void*,void*,void*,int,BOOL,void*,void*,void*);
typedef void (*UpdateSkillCDFunc)(void*,void*,void*,void*);
typedef void (*HandleSkillRangeFunc)(void*,void*,int32_t,void*);
typedef void (*HitSystemUpdateFunc)(void*,void*);
// MoveStep原函数8参数(不含MethodInfo*), hook函数9参数(含mi)
typedef void (*MoveStepFunc)(void*,void*,void*,void*,void*,void*,void*,void*);
// v116: Move方法 — static Boolean Move(Frame, Transform2D*, CharacterFiled*, FPVector2, FP, FP, Boolean)
// v115测试7参数hook playerTF始终NULL → MSHookFunction对此方法传了mi!
// v116: 8参数hook(含mi), 原函数指针7参数(不含mi)
typedef BOOL (*MoveOrigFunc)(void*,void*,void*,void*,void*,void*,BOOL);

// v116: 免广告 — hook IsAdAvailable返回false + AdsHelper单例字段修改
typedef BOOL (*IsAdAvailableFunc)(void*,int,BOOL);
// v117: 免广告 — hook ShowVideo跳过广告播放
// AdsHelper.ShowVideo(int adId, string adUnitId, bool multiton, bool isShow, bool isCardJump) — 5参数实例方法
typedef void (*ShowVideoFunc)(void*,int32_t,void*,BOOL,BOOL,BOOL);

static void *g_fUnlock=NULL; static BoolFunc3 g_oUnlock=NULL; static BOOL g_hUnlock=NO;
static void *g_fLimitDmg=NULL; static IntFunc1 g_oLimitDmg=NULL; static BOOL g_hLimitDmg=NO;
static void *g_fIsReady=NULL; static BoolFunc4 g_oIsReady=NULL; static BOOL g_hIsReady=NO;
static void *g_fAttackCanUse=NULL; static BoolFunc4 g_oAttackCanUse=NULL; static BOOL g_hAttackCanUse=NO;
static void *g_fCanBeAttack=NULL; static CanBeAttackFunc g_oCanBeAttack=NULL; static BOOL g_hCanBeAttack=NO;
static void *g_fDamage=NULL; static DamageFunc g_oDamage=NULL; static BOOL g_hDamage=NO;
static void *g_fIntersects=NULL; static IntersectsFunc g_oIntersects=NULL; static BOOL g_hIntersects=NO;
static void *g_fCheckHit=NULL; static CheckHitFunc g_oCheckHit=NULL; static BOOL g_hCheckHit=NO;
static void *g_fUseSkill=NULL; static UseSkillFunc g_oUseSkill=NULL; static BOOL g_hUseSkill=NO;
static void *g_fHandleSkillRange=NULL; static HandleSkillRangeFunc g_oHandleSkillRange=NULL; static BOOL g_hHandleSkillRange=NO;
static void *g_fUpdateSkillCD=NULL; static UpdateSkillCDFunc g_oUpdateSkillCD=NULL; static BOOL g_hUpdateSkillCD=NO;
static void *g_fHitSystemUpdate=NULL; static HitSystemUpdateFunc g_oHitSystemUpdate=NULL; static BOOL g_hHitSystemUpdate=NO;
static void *g_fMoveStep=NULL; static MoveStepFunc g_oMoveStep=NULL; static BOOL g_hMoveStep=NO;
// v116: Move方法hook
static void *g_fMove=NULL; static MoveOrigFunc g_oMove=NULL; static BOOL g_hMove=NO;
static int g_moveHookLC=0;
// v116: 免广告
static void *g_fIsAdAvailable=NULL; static IsAdAvailableFunc g_oIsAdAvailable=NULL; static BOOL g_hIsAdAvailable=NO;
// v117: 免广告 — ShowVideo hook
static void *g_fShowVideo=NULL; static ShowVideoFunc g_oShowVideo=NULL; static BOOL g_hShowVideo=NO;
// v117: AdsHelper类指针和单例
static void *g_classAdsHelper=NULL;
static void *g_adsHelperInstance=NULL;

// v120: 怪不动 — hook AIAgent.Update, 只冻结敌方, 玩家不受影响
// 前向声明g_playerEntity (在Damage hook中赋值)
static void *g_playerEntity=NULL;
// v119方案(已废弃): hook AISystem.Update → 玩家也受影响不动了！
// v120方案: hook AIAgent.Update(ref AIParams& Params) @ 0x30682cc
//   这是AIAgent struct的实例方法
//   读取AIParams中的_entity(EntityRef), 用EntityRef获取CharacterFiled, 判断Camp
//   Camp=0 → 玩家 → 正常执行(保留自动战斗)
//   Camp≠0 → 敌方 → 跳过Update → 不动+不攻击
//
// AIAgent.Update是struct的方法 → 第1参数是AIAgent*(self), 第2参数是ref AIParams&(指针)
// MSHookFunction可能传mi → hook 3参数(mi, self, params) 或 2参数(self, params)
//
// AIParams结构(值类型, dump offset含0x10伪header):
//   _frame @ dump 0x10 → actual 0x00
//   _agent* @ dump 0x18 → actual 0x08
//   _entity @ dump 0x20 → actual 0x10 (EntityRef.Raw=8字节)
//   _states @ dump 0x28 → actual 0x18
//   _root @ dump 0x30 → actual 0x20
// EntityRef.Raw非0 → 有效实体
typedef void (*AIAgentUpdateFunc)(void*, void*); // (self/AIAgent*, AIParams* ref)
static void *g_fAIAgentUpdate=NULL; static AIAgentUpdateFunc g_oAIAgentUpdate=NULL; static BOOL g_hAIAgentUpdate=NO;
static DecreaseHPFunc g_origDecreaseHP = NULL;
static void *g_classActor=NULL;

// v114: ChangeCharacterToDead hook — 静态方法，签名含MethodInfo*
// CharacterFiled.ChangeCharacterToDead(Frame f, EntityRef target, EntityRef atk, CharacterFiled* tgtCF, FP airImpulse, DeathEnum deathType, Boolean forceSwing)
// 原函数7参数(不含MethodInfo*), hook函数8参数(含mi)
typedef void (*ChangeCharacterToDeadOrigFunc)(void*,void*,void*,void*,int64_t,int32_t,BOOL);
static void *g_fChangeCharacterToDead=NULL; static ChangeCharacterToDeadOrigFunc g_oChangeCharacterToDead=NULL; static BOOL g_hChangeCharacterToDead=NO;

// v114: 吸怪 — MoveStep中记录Transform2D, 定时器持续拉X
static void *g_playerTransform2D=NULL;
static NSTimer *g_vacuumTimer=nil;
static int g_vacuumTickLC=0;
#define MAX_ENEMIES 64
static void *g_enemyCFs[MAX_ENEMIES], *g_enemyEntities[MAX_ENEMIES], *g_enemyTransforms[MAX_ENEMIES]; static int g_enemyCount=0;

@class JYJHActionHandler; // 前向声明

// v100: 不再需要这些函数指针 (不主动调用IL2CPP函数)
static void *g_fUpdatePart=NULL;          // LobbyActorData.UpdatePart - 仅记录地址

// v100: SetSecneData hook
static void *g_fSetSecneData=NULL; static void *g_oSetSecneData=NULL; static BOOL g_hSetSecneData=NO;
typedef void (*SetSecneDataOrigFunc)(void*,void*,void*);
static void *g_lobbyActorData=NULL;

static void *g_classLobbyActorData=NULL;
static void *g_classLobbyActorSpineAvatar=NULL;
static int32_t g_appliedSkinId=0, g_appliedWeaponId=0, g_appliedHaloId=0;
static int g_moveLC=0;

static BOOL isPlayerCF(void *cf) { if(!cf)return NO; int32_t v=-1; memcpy(&v,(uint8_t*)cf+0x44,4); return v==0; }
static BOOL isDeadCF(void *cf) { if(!cf)return NO; int32_t v=0; memcpy(&v,(uint8_t*)cf+0x48,4); return v!=0; }

static BOOL isValidPtr(void *p) {
    if(!p) return NO;
    uint64_t v=0; memcpy(&v,&p,8);
    return (v>=0x100000000ULL && v<=0x1FFFFFFFFFFFULL);
}

// ===== v100: SetSecneData hook =====
static int g_setSecneDataLC=0;
static void hSetSecneData(void *mi, void *self, void *sceneData) {
    if(g_oSetSecneData) ((SetSecneDataOrigFunc)g_oSetSecneData)(mi, self, sceneData);
    if(!self) return;
    
    BOOL isSelf = NO;
    memcpy(&isSelf, (uint8_t*)self + 0x2b, 1);
    if(!isSelf) return;
    
    g_lobbyActorData = self;
    
    if(!sceneData) return;
    
    if(g_setSecneDataLC < 10) {
        g_setSecneDataLC++;
        int32_t skinId=0, weaponId=0, fashionId=0;
        memcpy(&skinId, (uint8_t*)sceneData + 0x40, 4);
        memcpy(&weaponId, (uint8_t*)sceneData + 0x44, 4);
        memcpy(&fashionId, (uint8_t*)sceneData + 0x48, 4);
        jlog(@"SetSecneData[IsSelf]: skin=%d weapon=%d fashion=%d (applied: skin=%d weapon=%d halo=%d)", 
             skinId, weaponId, fashionId, g_appliedSkinId, g_appliedWeaponId, g_appliedHaloId);
    }
    
    if(g_appliedSkinId > 0) {
        memcpy((uint8_t*)sceneData + 0x40, &g_appliedSkinId, 4);
        jlog(@"v100: wrote skinId=%d to sceneData+0x40", g_appliedSkinId);
    }
    if(g_appliedWeaponId > 0) {
        memcpy((uint8_t*)sceneData + 0x44, &g_appliedWeaponId, 4);
        jlog(@"v100: wrote weaponId=%d to sceneData+0x44", g_appliedWeaponId);
    }
    
    if(g_appliedSkinId > 0 || g_appliedWeaponId > 0 || g_appliedHaloId > 0) {
        BOOL yes = YES;
        memcpy((uint8_t*)self + 0x28, &yes, 1);
        jlog(@"v100: set NeedUpdatePart=true");
    }
}

// ===== v120: AIAgent.Update Hook — 只冻结敌方AI, 玩家不受影响 =====
// v119方案(已废弃): hook AISystem.Update → 玩家也受影响不动了！
// v120方案: hook AIAgent.Update(ref AIParams& Params)
//   在hook中通过g_playerEntity判断: 如果这个AI是属于玩家的 → 放行
//   否则 → 跳过Update(怪不动+不攻击)
//   
// 简单方案: 用g_playerEntity(在Damage hook中捕获)来判断
//   如果params中的_entity == g_playerEntity → 放行(玩家自动战斗)
//   否则 → 跳过(敌方AI冻结)
//
// EntityRef.Raw在AIParams中的偏移:
//   dump offset 0x20, 值类型减0x10 → actual 0x10
//   但ref AIParams&是指针, params指向AIParams结构
//   直接读params+0x10就是_entity.Raw(8字节)
static int g_aiFreezeLC=0;
static void hAIAgentUpdate(void *mi_or_self, void *self_or_params, void *maybe_params) {
    if(g_monsterFreeze) {
        // 确定实际的params指针
        // 如果MSHookFunction传mi: mi_or_self=mi, self_or_params=self, maybe_params=params
        // 如果不传mi: mi_or_self=self, self_or_params=params, maybe_params=garbage
        // 用isValidPtr判断: self(AIAgent*)应是有效指针, mi也是有效指针但值不同
        // 简单方案: 假设不传mi(大多数IL2CPP实例方法不传)
        void *params = self_or_params;
        
        // 从AIParams读取_entity(EntityRef.Raw) @ params+0x10, 8字节
        uint64_t entityRaw = 0;
        if(params && isValidPtr(params)) {
            memcpy(&entityRaw, (uint8_t*)params + 0x10, 8);
        }
        
        // 判断是否是玩家实体
        // g_playerEntity是EntityRef(4字节Index), 需要匹配
        // 更简单的方案: 记录玩家EntityRef.Raw, 直接比较8字节
        uint64_t playerEntityRaw = 0;
        if(g_playerEntity) {
            memcpy(&playerEntityRaw, &g_playerEntity, 8); // g_playerEntity是void*存的EntityRef
        }
        
        BOOL isPlayer = (entityRaw != 0 && entityRaw == playerEntityRaw);
        
        if(!isPlayer && entityRaw != 0) {
            // 敌方AI → 跳过Update
            if(g_aiFreezeLC<10){g_aiFreezeLC++;jlog(@"AI: AIAgent.Update FROZEN entity=0x%llx (player=0x%llx)",entityRaw,playerEntityRaw);}
            return;
        }
        // 玩家AI → 放行(保留自动战斗)
    }
    // 调用原函数
    if(g_oAIAgentUpdate) g_oAIAgentUpdate(mi_or_self, self_or_params);
}

// ===== MoveStep Hook =====
// 重要结论: MoveStep p=8的IL2CPP静态方法, MSHookFunction不传MethodInfo*!
// 8参数签名是正确的(v100速度修改验证), 9参数会卡死
// 8参数时第8个参数tf实际是dt(FP值如0.888), 不是Transform2D指针
// 原因: MSHookFunction的trampoline对某些IL2CPP方法不插入mi参数
// 所以MoveStep hook无法获取Transform2D, 只用于速度修改
static void hMoveStep(void *f,void *entity,void *cf,void *moveDir,void *msx,void *msy,void *dt,void *tf) {
    // 速度修改 (v100验证可工作)
    if(g_speedMul>1.0f && cf && isPlayerCF(cf)) {
        int64_t origSpeed=0;
        memcpy(&origSpeed,(uint8_t*)cf+0x80,8);
        int64_t newSpeed = (int64_t)((double)origSpeed * g_speedMul);
        memcpy((uint8_t*)cf+0x80,&newSpeed,8);
        int64_t origSprint=0;
        memcpy(&origSprint,(uint8_t*)cf+0x88,8);
        int64_t newSprint = (int64_t)((double)origSprint * g_speedMul);
        memcpy((uint8_t*)cf+0x88,&newSprint,8);
        if(g_oMoveStep) g_oMoveStep(f,entity,cf,moveDir,msx,msy,dt,tf);
        memcpy((uint8_t*)cf+0x80,&origSpeed,8);
        memcpy((uint8_t*)cf+0x88,&origSprint,8);
        if(g_moveLC<10){g_moveLC++;jlog(@"MoveStep: speed×%.1f raw=%lld->%lld",g_speedMul,origSpeed,newSpeed);}
        return;
    }
    if(g_oMoveStep) g_oMoveStep(f,entity,cf,moveDir,msx,msy,dt,tf);
}

// ===== v117: Move Hook =====
// static Boolean Move(Frame f, Transform2D* tf, CharacterFiled* cf, FPVector2 targetPos, FP moveSpeed, FP fDeltaTime, Boolean updateFootY)
// 7参数静态方法
// v117: 精确匹配CharacterFiled.Move(pc==7), 不再匹配CharacterController3D.Move
// MSHookFunction对mi传递不确定: 先试8参数(含mi), v116验证8参数
// 增加详细调试日志打印所有参数值
static int g_moveDebugLC=0;
static BOOL hMove(void *mi,void *f,void *tf,void *cf,void *targetPos,void *moveSpeed,void *fDeltaTime,BOOL updateFootY) {
    // v117: 详细调试 — 前30次调用打印所有参数
    if(g_moveDebugLC < 30) {
        g_moveDebugLC++;
        jlog(@"Move[%d]: mi=%p f=%p tf=%p cf=%p targetPos=%p moveSpeed=%p fDeltaTime=%p updateFootY=%d validTF=%d",
             g_moveDebugLC, mi, f, tf, cf, targetPos, moveSpeed, fDeltaTime, updateFootY, isValidPtr(tf));
    }
    
    // 记录Transform2D指针
    if(cf && tf && isValidPtr(tf)) {
        if(isPlayerCF(cf)) {
            if(!g_playerTransform2D || g_playerTransform2D != tf) {
                g_playerTransform2D = tf;
                if(g_moveHookLC<20){g_moveHookLC++;jlog(@"Move: PLAYER tf=%p (v117)",tf);}
            }
        } else {
            // 敌人: 更新Transform2D指针
            for(int i=0;i<g_enemyCount;i++) {
                if(g_enemyCFs[i]==cf) {
                    g_enemyTransforms[i]=tf;
                    break;
                }
            }
        }
    } else if(g_moveHookLC<5) {
        g_moveHookLC++;
        jlog(@"Move: cf=%p tf=%p valid=%d", cf, tf, tf?isValidPtr(tf):0);
    }
    
    if(g_oMove) return g_oMove(f,tf,cf,targetPos,moveSpeed,fDeltaTime,updateFootY);
    return NO;
}

// ===== HitSystem =====
#define HITSYS_COLLBOUND_OFF 0x38
#define HITSYS_EXTENTS_X_OFF (HITSYS_COLLBOUND_OFF+0x10)
#define HITSYS_EXTENTS_Y_OFF (HITSYS_COLLBOUND_OFF+0x18)
static int64_t g_savedExtX=0, g_savedExtY=0;
static void *g_playerCF=NULL; static BOOL g_playerCFLearned=NO;

// v115: 真正的吸怪 — 修改Transform2D.Position.X把怪拉到玩家同一X线
// Transform2D struct: Position.X @ tf+0x00 (8字节 FP.RawValue), Position.Y @ tf+0x08
static int g_vacuumTotalTicks=0;

static void vacuumTick(NSTimer *t) {
    g_vacuumTotalTicks++;
    
    if(!g_playerTransform2D) {
        if(g_vacuumTotalTicks % 50 == 1) jlog(@"vacuumTick[%d]: no playerTF yet", g_vacuumTotalTicks);
        return;
    }
    
    // 读取玩家Position.X
    int64_t playerX_raw=0;
    memcpy(&playerX_raw, (uint8_t*)g_playerTransform2D + 0x00, 8);
    
    // 遍历所有敌人, 把Position.X改成玩家的X
    int pulled=0;
    for(int i=0; i<g_enemyCount; i++) {
        if(!g_enemyTransforms[i]) continue;
        if(!isValidPtr(g_enemyTransforms[i])) { g_enemyTransforms[i]=NULL; continue; }
        
        // 检查敌人是否还活着
        if(g_enemyCFs[i] && isDeadCF(g_enemyCFs[i])) {
            g_enemyTransforms[i]=NULL;
            continue;
        }
        
        // 读取敌人当前X
        int64_t enemyX_raw=0;
        memcpy(&enemyX_raw, (uint8_t*)g_enemyTransforms[i] + 0x00, 8);
        
        // 如果X不同, 修改为玩家X
        if(enemyX_raw != playerX_raw) {
            memcpy((uint8_t*)g_enemyTransforms[i] + 0x00, &playerX_raw, 8);
            pulled++;
        }
    }
    
    if(g_vacuumTotalTicks % 50 == 1) {
        jlog(@"vacuumTick[%d]: playerTF=%p playerX=0x%llx pulled=%d enemies=%d", 
             g_vacuumTotalTicks, g_playerTransform2D, playerX_raw, pulled, g_enemyCount);
    }
}

// NSTimer helper: 用JYJHActionHandler作为target
static void startVacuumTimer(void) {
    if(g_vacuumTimer) return;
    g_vacuumTickLC=0;
    g_vacuumTotalTicks=0;
    g_vacuumTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:[JYJHActionHandler shared] selector:@selector(vacuumTickFire:) userInfo:nil repeats:YES];
    jlog(@"vacuum: NSTimer started");
}

static void stopVacuumTimer(void) {
    if(g_vacuumTimer) { 
        [g_vacuumTimer invalidate]; 
        g_vacuumTimer=nil; 
        jlog(@"vacuum: NSTimer stopped"); 
    }
}

// ===== 皮肤/武器/光环扫描 =====
static void *g_classUnityGameEntry=NULL;
static void *g_classHotfixGameEntry=NULL;
static void *g_classConfigComponent=NULL;
static void *g_classHotfixConfigComponent=NULL;
#define MAX_GAME_ENTRIES 8
static void *g_allGameEntries[MAX_GAME_ENTRIES];
static const char *g_allGameEntryNS[MAX_GAME_ENTRIES];
static int g_gameEntryCount=0;
#define MAX_SKIN_IDS 256
static int32_t g_roleSkinIds[MAX_SKIN_IDS], g_weaponSkinIds[MAX_SKIN_IDS], g_haloSkinIds[MAX_SKIN_IDS];
static int g_roleSkinCount=0, g_weaponSkinCount=0, g_haloSkinCount=0;
static BOOL g_skinIdsLoaded=NO;

static void *getStaticData(void *klass) {
    if(!klass) return NULL;
    void *h=dlopen(NULL,RTLD_LAZY); if(!h) return NULL;
    typedef void* (*Fn)(void*);
    Fn func=(Fn)dlsym(h,"il2cpp_class_get_static_field_data");
    if(!func) return NULL;
    return func(klass);
}

static const char *getObjClassName(void *obj) {
    if(!obj) return NULL;
    void *klass=NULL; memcpy(&klass,(uint8_t*)obj,8); if(!klass) return NULL;
    void *h=dlopen(NULL,RTLD_LAZY); if(!h) return NULL;
    typedef const char* (*Fn)(void*);
    Fn func=(Fn)dlsym(h,"il2cpp_class_get_name");
    return func ? func(klass) : NULL;
}

static const char *getObjClassNamespace(void *obj) {
    if(!obj) return NULL;
    void *klass=NULL; memcpy(&klass,(uint8_t*)obj,8); if(!klass) return NULL;
    void *h=dlopen(NULL,RTLD_LAZY); if(!h) return NULL;
    typedef const char* (*Fn)(void*);
    Fn func=(Fn)dlsym(h,"il2cpp_class_get_namespace");
    return func ? func(klass) : NULL;
}

static void *getConfigViaHotfixEntry(void) {
    if(!g_classHotfixGameEntry) return NULL;
    void *sd=getStaticData(g_classHotfixGameEntry);
    if(!isValidPtr(sd)) return NULL;
    jlog(@"getConfigHF: SD=%p",sd);
    void *config=NULL; memcpy(&config,(uint8_t*)sd+0xa8,8);
    if(isValidPtr(config)) { jlog(@"getConfigHF: config=%p",config); return config; }
    return NULL;
}

static void *getConfigViaComponentList(void) {
    if(!g_classUnityGameEntry) return NULL;
    void *sd=getStaticData(g_classUnityGameEntry);
    if(!isValidPtr(sd)) return NULL;
    void *listObj=NULL; memcpy(&listObj,(uint8_t*)sd+0x0,8);
    if(!isValidPtr(listObj)) return NULL;
    for(int off=0;off<128;off+=8){
        void *p=NULL; memcpy(&p,(uint8_t*)listObj+off,8);
        if(!isValidPtr(p)) continue;
        const char *cn=getObjClassName(p); if(!cn) continue;
        const char *ns=getObjClassNamespace(p);
        if(strcmp(cn,"ConfigComponent")==0){
            if(ns&&strstr(ns,"HotfixFramework")!=NULL) return p;
            if(!g_classConfigComponent) g_classConfigComponent=p;
        }
    }
    if(g_classConfigComponent) return g_classConfigComponent;
    return NULL;
}

static void *getConfigComponent(void) {
    void *cc=getConfigViaHotfixEntry();
    if(cc) return cc;
    return getConfigViaComponentList();
}

static int readTableIds(void *tables_l, int tableOff, int32_t *outIds, int maxIds, const char *tableName) {
    int count = 0;
    void *tbObj = NULL; memcpy(&tbObj, (uint8_t*)tables_l + tableOff, 8);
    if(!isValidPtr(tbObj)) { jlog(@"ScanTable(%s): +0x%x invalid", tableName, tableOff); return 0; }
    void *dataList = NULL; memcpy(&dataList, (uint8_t*)tbObj + 0x18, 8);
    if(!isValidPtr(dataList)) { jlog(@"ScanTable(%s): _dataList invalid", tableName); return 0; }
    void *itemsArray = NULL; int32_t listSize = 0;
    for(int itemsOff = 0x10; itemsOff <= 0x28; itemsOff += 8) {
        void *testArr = NULL; int32_t testSize = 0;
        memcpy(&testArr, (uint8_t*)dataList + itemsOff, 8);
        int sizeOff = itemsOff + 8;
        if(sizeOff + 4 <= 96) memcpy(&testSize, (uint8_t*)dataList + sizeOff, 4);
        if(isValidPtr(testArr) && testSize > 0 && testSize < 10000) {
            int32_t testArrLen = 0; memcpy(&testArrLen, (uint8_t*)testArr + 0x18, 4);
            if(testArrLen >= testSize && testArrLen < 100000) { itemsArray = testArr; listSize = testSize; break; }
            memcpy(&testArrLen, (uint8_t*)testArr + 0x10, 4);
            if(testArrLen >= testSize && testArrLen < 100000) { itemsArray = testArr; listSize = testSize; break; }
        }
    }
    if(!itemsArray || listSize <= 0) return 0;
    int32_t arrayLen = 0; memcpy(&arrayLen, (uint8_t*)itemsArray + 0x18, 4);
    if(arrayLen <= 0 || arrayLen > 100000) memcpy(&arrayLen, (uint8_t*)itemsArray + 0x10, 4);
    int maxScan = (listSize < maxIds) ? listSize : maxIds;
    for(int i = 0; i < maxScan && i < arrayLen; i++) {
        void *p = NULL; memcpy(&p, (uint8_t*)itemsArray + 0x20 + i * 8, 8);
        if(!p) continue;
        int32_t id = 0; memcpy(&id, (uint8_t*)p + 0x10, 4);
        if(id > 0) outIds[count++] = id;
    }
    jlog(@"ScanTable(%s): found %d IDs at +0x%x", tableName, count, tableOff);
    return count;
}

static void scanSkinIds(void) {
    if(g_skinIdsLoaded) return;
    g_roleSkinCount=0; g_weaponSkinCount=0; g_haloSkinCount=0;
    void *cc=getConfigComponent();
    if(!isValidPtr(cc)){jlog(@"ScanSkin: ConfigComponent NULL");return;}
    void *tables_l=NULL; memcpy(&tables_l,(uint8_t*)cc+0x28,8);
    if(!isValidPtr(tables_l)){jlog(@"ScanSkin: tables invalid");return;}
    
    g_roleSkinCount = readTableIds(tables_l, 0x230, g_roleSkinIds, MAX_SKIN_IDS, "RoleSkin");
    for(int i=0;i<g_roleSkinCount&&i<20;i++) jlog(@"  RoleSkin[%d]=%d",i,g_roleSkinIds[i]);
    
    g_weaponSkinCount = readTableIds(tables_l, 0x248, g_weaponSkinIds, MAX_SKIN_IDS, "WeaponSkin");
    for(int i=0;i<g_weaponSkinCount&&i<20;i++) jlog(@"  WeaponSkin[%d]=%d",i,g_weaponSkinIds[i]);
    
    g_haloSkinCount = readTableIds(tables_l, 0x258, g_haloSkinIds, MAX_SKIN_IDS, "HaloSkin");
    for(int i=0;i<g_haloSkinCount&&i<20;i++) jlog(@"  HaloSkin[%d]=%d",i,g_haloSkinIds[i]);
    
    g_skinIdsLoaded=YES;
}

static void trackEnemy(void *cf, void *ent) {
    if(!cf||isPlayerCF(cf))return;
    for(int i=0;i<g_enemyCount;i++) if(g_enemyCFs[i]==cf){g_enemyEntities[i]=ent;return;}
    if(g_enemyCount<MAX_ENEMIES){
        g_enemyCFs[g_enemyCount]=cf;
        g_enemyEntities[g_enemyCount]=ent;
        g_enemyTransforms[g_enemyCount]=NULL; // 会在Move hook中更新
        g_enemyCount++;
        if(g_enemyCount<=5) jlog(@"trackEnemy[%d]: cf=%p ent=%p",g_enemyCount-1,cf,ent);
    }
}

// ===== Hooks =====
static int g_unlockLC=0;
static BOOL hUnlock(void *s,int a1,int a2){if(g_ignoreUnlock){if(g_unlockLC<5){g_unlockLC++;}return YES;}return g_oUnlock?g_oUnlock(s,a1,a2):YES;}

static int g_isReadyLC=0;
static BOOL hIsReady(void *f,int st,void *cf,void *st2){
    if(cf){if(isPlayerCF(cf)){if(!g_playerCFLearned){g_playerCF=cf;g_playerCFLearned=YES;}}else trackEnemy(cf,NULL);}
    if(g_skillReplace&&st>=14&&st<=19){if(g_isReadyLC<30){g_isReadyLC++;}return YES;}
    if(g_exSkillNoCD&&st>=17){return YES;}
    return g_oIsReady?g_oIsReady(f,st,cf,st2):YES;
}

static int g_attackLC=0;
static BOOL hAttackCanUse(void *f,int st,void *cf,void *st2){
    if(cf&&isPlayerCF(cf)&&!g_playerCFLearned){g_playerCF=cf;g_playerCFLearned=YES;}
    if(g_skillReplace&&st>=14&&st<=19){if(g_attackLC<30){g_attackLC++;}return YES;}
    if(g_exSkillNoCD&&st>=17){return YES;}
    return g_oAttackCanUse?g_oAttackCanUse(f,st,cf,st2):YES;
}

static int hLimitDmg(void *s){return g_damageLimit;}

static int g_canBeAtkLC=0;
static BOOL hCanBeAttack(void *cf){
    if(cf){if(isPlayerCF(cf)&&g_godMode){if(g_canBeAtkLC<20)g_canBeAtkLC++;return NO;}else if(!isPlayerCF(cf))trackEnemy(cf,NULL);}
    return g_oCanBeAttack?g_oCanBeAttack(cf):YES;
}

static int g_dmgLC=0;
static int64_t hDamage(void *f,void *atkEnt,void *atkCF,void *tgtEnt,void *tgtCF,
    int32_t hitEid,int32_t hitSnd,BOOL isR,int32_t sBtn,int32_t sPart,void *hurtF,void *exS){
    BOOL tgtP=(tgtCF&&isPlayerCF(tgtCF)), atkP=(atkCF&&isPlayerCF(atkCF));
    if(atkP&&atkEnt)g_playerEntity=atkEnt;
    if(tgtCF&&!tgtP&&tgtEnt)trackEnemy(tgtCF,tgtEnt);
    if(g_godMode&&tgtP){if(g_dmgLC<20){g_dmgLC++;}return 0;}
    if(!g_oDamage)return 0;
    int64_t r=g_oDamage(f,atkEnt,atkCF,tgtEnt,tgtCF,hitEid,hitSnd,isR,sBtn,sPart,hurtF,exS);
    if(atkP && g_damageMulti>1 && !tgtP) {
        for(int i=1;i<g_damageMulti;i++){
            g_oDamage(f,atkEnt,atkCF,tgtEnt,tgtCF,hitEid,hitSnd,isR,sBtn,sPart,hurtF,exS);
        }
        if(g_dmgLC<20){g_dmgLC++;jlog(@"Dmg[%d]=%lld ×%d",g_dmgLC,r,g_damageMulti);}
    }
    return r;
}

// v114: hook ChangeCharacterToDead — 阻止玩家死亡
// IL2CPP静态方法签名: (MethodInfo*, Frame f, EntityRef target, EntityRef atk, CharacterFiled* tgtCF, FP airImpulse, DeathEnum deathType, Boolean forceSwing)
static int g_deadLC=0;
static void hChangeCharacterToDead(void *mi,void *f,void *target,void *atk,void *tgtCF,int64_t airImpulse,int32_t deathType,BOOL forceSwing) {
    if(g_godMode && tgtCF && isPlayerCF(tgtCF)) {
        if(g_deadLC<5){g_deadLC++;jlog(@"GOD: Blocked death (type=%d)",deathType);}
        // 设置Invincible=1 (cf+0x00) + isDead=0 (cf+0x48)
        uint8_t inv=1; memcpy((uint8_t*)tgtCF,&inv,1);
        int32_t notDead=0; memcpy((uint8_t*)tgtCF+0x48,&notDead,4);
        return; // 直接return不调用原函数
    }
    if(g_oChangeCharacterToDead) g_oChangeCharacterToDead(f,target,atk,tgtCF,airImpulse,deathType,forceSwing);
}

static BOOL hIntersects(void *s,void *o){if(g_fullScreen)return YES;return g_oIntersects?g_oIntersects(s,o):NO;}
static int32_t hCheckHit(void *f,void *cb){if(g_fullScreen)return 1;return g_oCheckHit?g_oCheckHit(f,cb):0;}

static int g_useSkillLC=0;
static void hUseSkill(void *f,void *entity,void *cf,int skillStateType,BOOL isRight,void *states,void *state,void *playerInfo) {
    if(g_skillReplace && skillStateType>=14 && skillStateType<=18) {
        if(cf) {
            int32_t isAI=1; memcpy(&isAI,(uint8_t*)cf+0x44,4);
            if(isAI==0) {
                BOOL shouldReplace = NO;
                if(skillStateType==14 && g_replaceSkill1) shouldReplace=YES;
                if(skillStateType==15 && g_replaceSkill2) shouldReplace=YES;
                if(skillStateType==16 && g_replaceSkill3) shouldReplace=YES;
                if(skillStateType==17 && g_replaceSkill4) shouldReplace=YES;
                if(skillStateType==18 && g_replaceSkill5) shouldReplace=YES;
                if(shouldReplace) {
                    if(g_useSkillLC<30){g_useSkillLC++;jlog(@"UseSkill: player st=%d->19",skillStateType);}
                    skillStateType=19;
                }
            }
        }
    }
    if(g_oUseSkill) g_oUseSkill(f,entity,cf,skillStateType,isRight,states,state,playerInfo);
}

static int g_uscdLC=0;
static void hUpdateSkillCD(void *f,void *er,void *cf,void *states) {
    if(g_skillReplace) {
        if(g_uscdLC<20){g_uscdLC++;jlog(@"UpdateSkillCD: skipped (replace mode)");}
        return;
    }
    if(g_oUpdateSkillCD) g_oUpdateSkillCD(f,er,cf,states);
}

static int g_hitSysLC=0;
static void hHitSystemUpdate(void *self, void *framePtr) {
    if(!self) { if(g_oHitSystemUpdate) g_oHitSystemUpdate(self, framePtr); return; }
    if(g_hitSysLC<3) { g_hitSysLC++; }
    
    // v118: 攻击范围+ — 扩大HitSystem的collBound.Extents
    // FPBounds2结构: Center(FPVector2)@+0x10, Extents(FPVector2)@+0x20
    // 每个FPVector2是16字节(X@+0, Y@+8, 各8字节FP.RawValue)
    // collBound在HitSystem中offset=0x38
    // 所以Extents.X = self+0x38+0x20+0x00 = self+0x58
    //      Extents.Y = self+0x38+0x20+0x08 = self+0x60
    if(g_attackRangePlus || g_fullScreen) {
        uint8_t *p=(uint8_t*)self;
        memcpy(&g_savedExtX, p+HITSYS_EXTENTS_X_OFF, 8);
        memcpy(&g_savedExtY, p+HITSYS_EXTENTS_Y_OFF, 8);
        if(g_fullScreen) {
            // v120修复: 全屏秒杀不再用INT64_MAX(0x7FFFFFFFFFFFFFFF)
            // INT64_MAX会导致FP算术溢出 → 死循环卡死
            // 改用0x100000000 = 65536.0 in FP, 足够大的范围(覆盖整个地图)
            int64_t huge=0x100000000LL;
            memcpy(p+HITSYS_EXTENTS_X_OFF, &huge, 8);
            memcpy(p+HITSYS_EXTENTS_Y_OFF, &huge, 8);
        } else {
            // 攻击范围+: 扩大10倍(0x0A000000 = 10.0 in FP, 但用更安全的方式)
            // FP是定点数, RawValue = float_value * 65536
            // 10倍: 直接左移或乘法
            // 更简单: 直接设一个很大的值, 但不是INT64_MAX
            // 用0x100000000 = 65536.0 in FP → 足够大的范围
            int64_t bigRange = g_savedExtX * 10; // 10倍范围
            if(bigRange < g_savedExtX) bigRange = 0x100000000LL; // 溢出保护
            int64_t bigRangeY = g_savedExtY * 10;
            if(bigRangeY < g_savedExtY) bigRangeY = 0x100000000LL;
            memcpy(p+HITSYS_EXTENTS_X_OFF, &bigRange, 8);
            memcpy(p+HITSYS_EXTENTS_Y_OFF, &bigRangeY, 8);
        }
        if(g_oHitSystemUpdate) g_oHitSystemUpdate(self, framePtr);
        memcpy(p+HITSYS_EXTENTS_X_OFF, &g_savedExtX, 8);
        memcpy(p+HITSYS_EXTENTS_Y_OFF, &g_savedExtY, 8);
        return;
    }
    if(g_oHitSystemUpdate) g_oHitSystemUpdate(self, framePtr);
}

// ===== IL2CPP Search =====
typedef void* (*Il2CppDomainGet)(void);
typedef void** (*Il2CppDomainGetAssemblies)(void*,size_t*);
typedef void* (*Il2CppAssemblyGetImage)(void*);
typedef size_t (*Il2CppImageGetClassCount)(void*);
typedef void* (*Il2CppImageGetClass)(void*,size_t);
typedef void* (*Il2CppClassGetMethods)(void*,void**);
typedef const char* (*Il2CppMethodGetName)(void*);
typedef uint32_t (*Il2CppMethodGetParamCount)(void*);
typedef const char* (*Il2CppClassGetName)(void*);
typedef const char* (*Il2CppClassGetNamespace)(void*);

static void findIL2CPP(void) {
    jlog(@"=== v120 IL2CPP Search ===");
    void *h=dlopen(NULL,RTLD_LAZY); if(!h){jlog(@"dlopen FAIL");return;}
    Il2CppDomainGet domain_get=dlsym(h,"il2cpp_domain_get");
    Il2CppDomainGetAssemblies get_assemblies=dlsym(h,"il2cpp_domain_get_assemblies");
    Il2CppAssemblyGetImage get_image=dlsym(h,"il2cpp_assembly_get_image");
    Il2CppImageGetClassCount class_count=dlsym(h,"il2cpp_image_get_class_count");
    Il2CppImageGetClass get_class=dlsym(h,"il2cpp_image_get_class");
    Il2CppClassGetMethods get_methods=dlsym(h,"il2cpp_class_get_methods");
    Il2CppMethodGetName method_name=dlsym(h,"il2cpp_method_get_name");
    Il2CppMethodGetParamCount param_count=dlsym(h,"il2cpp_method_get_param_count");
    Il2CppClassGetName class_name_func=dlsym(h,"il2cpp_class_get_name");
    Il2CppClassGetNamespace class_get_namespace=dlsym(h,"il2cpp_class_get_namespace");
    typedef void* (*Il2CppClassGetFields)(void*,void*);
    Il2CppClassGetFields get_fields=dlsym(h,"il2cpp_class_get_fields");
    typedef const char* (*Il2CppFieldGetName)(void*);
    Il2CppFieldGetName field_name=dlsym(h,"il2cpp_field_get_name");
    typedef int32_t (*Il2CppFieldGetOffset)(void*);
    Il2CppFieldGetOffset field_offset=dlsym(h,"il2cpp_field_get_offset");
    typedef void* (*Il2CppFieldGetType)(void*);
    Il2CppFieldGetType field_type=dlsym(h,"il2cpp_field_get_type");
    
    if(!domain_get||!method_name){jlog(@"IL2CPP APIs not found");return;}
    void *domain=domain_get(); if(!domain)return;
    size_t assemCount=0; void **assemblies=get_assemblies(domain,&assemCount);
    if(!assemblies)return;
    
    // v98: 用运行时API获取真实字段偏移
    if(g_classLobbyActorData && get_fields && field_name && field_offset) {
        jlog(@"=== v98: Dump LobbyActorData fields (runtime offsets) ===");
        void *fiter=NULL, *field=NULL;
        while((field=get_fields(g_classLobbyActorData,&fiter))!=NULL) {
            const char *fn=field_name(field);
            int32_t off=field_offset(field);
            jlog(@"  LobbyActorData field: %s @ offset 0x%x (%d)", fn?:"?", off, off);
        }
    }
    if(g_classLobbyActorSpineAvatar && get_fields && field_name && field_offset) {
        jlog(@"=== v98: Dump LobbyActorSpineAvatar fields (runtime offsets) ===");
        void *fiter=NULL, *field=NULL;
        while((field=get_fields(g_classLobbyActorSpineAvatar,&fiter))!=NULL) {
            const char *fn=field_name(field);
            int32_t off=field_offset(field);
            jlog(@"  LobbyActorSpineAvatar field: %s @ offset 0x%x (%d)", fn?:"?", off, off);
        }
    }
    typedef void* (*Il2CppClassFromName)(void*,const char*,const char*);
    Il2CppClassFromName class_from_name=dlsym(h,"il2cpp_class_from_name");
    if(class_from_name && get_fields && field_name && field_offset) {
        for(size_t a=0;a<assemCount;a++){
            void *img=get_image(assemblies[a]); if(!img)continue;
            void *spklass=class_from_name(img,"HotfixBusiness.UnityWebSocket","ScenePlayerData");
            if(spklass) {
                jlog(@"=== v98: Dump ScenePlayerData fields ===");
                void *fiter=NULL, *field=NULL;
                while((field=get_fields(spklass,&fiter))!=NULL) {
                    const char *fn=field_name(field);
                    int32_t off=field_offset(field);
                    jlog(@"  ScenePlayerData field: %s @ 0x%x", fn?:"?", off);
                }
                break;
            }
        }
        for(size_t a=0;a<assemCount;a++){
            void *img=get_image(assemblies[a]); if(!img)continue;
            void *adklass=class_from_name(img,"Hotfix.HotfixBusiness","ActorData");
            if(adklass) {
                jlog(@"=== v98: Dump ActorData fields ===");
                void *fiter=NULL, *field=NULL;
                while((field=get_fields(adklass,&fiter))!=NULL) {
                    const char *fn=field_name(field);
                    int32_t off=field_offset(field);
                    jlog(@"  ActorData field: %s @ 0x%x", fn?:"?", off);
                }
                break;
            }
        }
    }
    
    int found=0,totalMethods=0;
    for(size_t a=0;a<assemCount;a++){
        void *img=get_image(assemblies[a]); if(!img)continue;
        size_t cnt=class_count?class_count(img):0;
        for(size_t c=0;c<cnt;c++){
            void *klass=get_class(img,c); if(!klass)continue;
            const char *cn=class_name_func?class_name_func(klass):NULL;
            const char *ns=class_get_namespace?class_get_namespace(klass):NULL;
            if(cn&&strcmp(cn,"Actor")==0&&!g_classActor){g_classActor=klass;jlog(@"FOUND class Actor=%p",klass);}
            if(cn&&strcmp(cn,"LobbyActorData")==0&&!g_classLobbyActorData){g_classLobbyActorData=klass;jlog(@"FOUND class LobbyActorData=%p",klass);}
            if(cn&&strcmp(cn,"LobbyActorSpineAvatar")==0&&!g_classLobbyActorSpineAvatar){g_classLobbyActorSpineAvatar=klass;jlog(@"FOUND class LobbyActorSpineAvatar=%p",klass);}
            if(cn&&strcmp(cn,"GameEntry")==0&&g_gameEntryCount<MAX_GAME_ENTRIES){
                g_allGameEntries[g_gameEntryCount]=klass;
                g_allGameEntryNS[g_gameEntryCount]=ns?strdup(ns):NULL;
                g_gameEntryCount++;
                if(ns&&strcmp(ns,"UnityGameFramework.Runtime")==0&&!g_classUnityGameEntry) g_classUnityGameEntry=klass;
                if(ns&&strcmp(ns,"HotfixFramework.Runtime")==0&&!g_classHotfixGameEntry) g_classHotfixGameEntry=klass;
            }
            if(cn&&strcmp(cn,"ConfigComponent")==0){
                if(ns&&strstr(ns,"HotfixFramework")!=NULL&&!g_classHotfixConfigComponent) g_classHotfixConfigComponent=klass;
                if(ns&&strcmp(ns,"UnityGameFramework.Runtime")==0&&!g_classConfigComponent) g_classConfigComponent=klass;
                if(!ns&&!g_classConfigComponent) g_classConfigComponent=klass;
            }
            void *iter=NULL,*m=NULL;
            while((m=get_methods(klass,&iter))!=NULL){
                totalMethods++;
                const char *n=method_name(m); if(!n)continue;
                uint32_t pc=param_count?param_count(m):0;
                void *fa=NULL; memcpy(&fa,m,sizeof(void*));
                if(strcmp(n,"CheckSkillUnlock")==0&&!g_fUnlock){g_fUnlock=fa;found++;jlog(@"FOUND %s.%s p=%u %p",cn?:"?",n,pc,fa);}
                else if(strcmp(n,"get_limitDamage")==0&&!g_fLimitDmg){g_fLimitDmg=fa;found++;jlog(@"FOUND %s.%s p=%u %p",cn?:"?",n,pc,fa);}
                else if(strcmp(n,"CheckSkillIsReady")==0&&!g_fIsReady){g_fIsReady=fa;found++;jlog(@"FOUND %s.%s p=%u %p",cn?:"?",n,pc,fa);}
                else if(strcmp(n,"CheckSkillAttackCanUse")==0&&!g_fAttackCanUse){g_fAttackCanUse=fa;found++;jlog(@"FOUND %s.%s p=%u %p",cn?:"?",n,pc,fa);}
                else if(strcmp(n,"CanBeAttack")==0&&!g_fCanBeAttack){g_fCanBeAttack=fa;found++;jlog(@"FOUND %s.%s p=%u %p",cn?:"?",n,pc,fa);}
                else if(strcmp(n,"Damage")==0&&pc>=10&&!g_fDamage){g_fDamage=fa;found++;jlog(@"FOUND %s.%s p=%u %p",cn?:"?",n,pc,fa);}
                else if(strcmp(n,"DecreaseHP")==0&&pc==5){if(!g_origDecreaseHP){g_origDecreaseHP=(DecreaseHPFunc)fa;}}
                else if(strcmp(n,"Intersects")==0&&pc==1&&cn&&strstr(cn,"FPBounds2")!=NULL&&!g_fIntersects){g_fIntersects=fa;found++;jlog(@"FOUND %s.%s p=%u %p",cn?:"?",n,pc,fa);}
                else if(strcmp(n,"CheckPlayerHitCollider")==0&&pc==2&&!g_fCheckHit){g_fCheckHit=fa;found++;jlog(@"FOUND %s.%s p=%u %p",cn?:"?",n,pc,fa);}
                else if(strcmp(n,"Update")==0&&pc==1&&cn&&strcmp(cn,"HitSystem")==0&&!g_fHitSystemUpdate){g_fHitSystemUpdate=fa;found++;jlog(@"FOUND %s.%s p=%u %p",cn?:"?",n,pc,fa);}
                else if(strcmp(n,"HandleSkillRange")==0&&pc>=3&&!g_fHandleSkillRange){g_fHandleSkillRange=fa;found++;}
                else if(strcmp(n,"UseSkill")==0&&pc>=7&&cn&&strcmp(cn,"AttackSystem")==0&&!g_fUseSkill){g_fUseSkill=fa;found++;jlog(@"FOUND %s.%s p=%u %p",cn,n,pc,fa);}
                else if(strcmp(n,"UpdateSkillCoolDown")==0&&pc>=3&&cn&&strcmp(cn,"AttackSystem")==0&&!g_fUpdateSkillCD){g_fUpdateSkillCD=fa;found++;}
                else if(strcmp(n,"MoveStep")==0&&pc>=7&&!g_fMoveStep){g_fMoveStep=fa;found++;}
                // v117: 搜索CharacterFiled.Move — 精确匹配类名+参数数!
                // v116 bug: strstr(cn,"Character")匹配到了CharacterController3D.Move(3D控制器, 无Transform2D*)
                // CharacterFiled.Move(Frame, Transform2D*, CharacterFiled*, FPVector2, FP, FP, Boolean) = 7参数
                // CharacterFiled还有一个void Move(Frame,EntityRef,CharacterFiled*,FPVector2,FP,FP,CharacterStatesAsset)也是7参数
                // 但带Transform2D*的是第一个, 两个都pc==7
                // 用strcmp精确匹配"CharacterFiled", 且pc==7
                else if(strcmp(n,"Move")==0&&pc==7&&!g_fMove&&cn&&strcmp(cn,"CharacterFiled")==0){g_fMove=fa;found++;jlog(@"FOUND %s.%s p=%u %p (v117 vacuum)",cn?:"?",n,pc,fa);}
                else if(strcmp(n,"UpdatePart")==0&&pc==3&&cn&&strcmp(cn,"LobbyActorData")==0&&!g_fUpdatePart){g_fUpdatePart=fa;found++;jlog(@"FOUND %s.%s p=%u %p",cn,n,pc,fa);}
                else if(strcmp(n,"SetSecneData")==0&&pc==1&&cn&&strcmp(cn,"LobbyActorData")==0&&!g_fSetSecneData){g_fSetSecneData=fa;found++;jlog(@"FOUND %s.%s p=%u %p",cn,n,pc,fa);}
                // v114: 搜索ChangeCharacterToDead (7参数静态方法)
                else if(strcmp(n,"ChangeCharacterToDead")==0&&!g_fChangeCharacterToDead){g_fChangeCharacterToDead=fa;found++;jlog(@"FOUND %s.%s p=%u %p (v114 godMode)",cn?:"?",n,pc,fa);}
                // v116: 搜索IsAdAvailable — AdsHelper.IsAdAvailable(int id, bool showButton)
                else if(strcmp(n,"IsAdAvailable")==0&&!g_fIsAdAvailable){g_fIsAdAvailable=fa;found++;jlog(@"FOUND %s.%s p=%u %p (v116 noAds)",cn?:"?",n,pc,fa);}
                // v117: 搜索ShowVideo — AdsHelper.ShowVideo(int adId, string adUnitId, bool multiton, bool isShow, bool isCardJump) p=5
                else if(strcmp(n,"ShowVideo")==0&&pc==5&&!g_fShowVideo&&cn&&strstr(cn,"AdsHelper")!=NULL){g_fShowVideo=fa;found++;jlog(@"FOUND %s.%s p=%u %p (v117 noAds)",cn?:"?",n,pc,fa);}
                // v120: 搜索AIAgent.Update — 怪不动功能(只冻结敌方)
                // v119方案(废弃): hook AISystem.Update → 玩家也受影响
                // v120方案: hook AIAgent.Update → 只冻结敌方, 玩家正常
                else if(strcmp(n,"Update")==0&&pc==1&&cn&&strcmp(cn,"AIAgent")==0&&!g_fAIAgentUpdate){g_fAIAgentUpdate=fa;found++;jlog(@"FOUND %s.%s p=%u %p (v120 freeze)",cn,n,pc,fa);}
                // v117: 记录AdsHelper类指针
                if(cn&&strstr(cn,"AdsHelper")!=NULL&&!g_classAdsHelper){g_classAdsHelper=klass;jlog(@"FOUND class AdsHelper=%p (v117)",klass);}
            }
        }
    }
    if(!g_classHotfixGameEntry){
        for(int i=0;i<g_gameEntryCount;i++){
            if(g_allGameEntryNS[i]==NULL||strcmp(g_allGameEntryNS[i],"")==0){
                g_classHotfixGameEntry=g_allGameEntries[i]; break;
            }
        }
    }
    jlog(@"v120: Move=%p AIAgentUpdate=%p", g_fMove, g_fAIAgentUpdate);
    jlog(@"Scanned %d methods, found %d targets",totalMethods,found);
}

static void hookOneFunc(void *fa,void *hf,void **of,BOOL *hf2,const char *name){
    if(!fa){jlog(@"%s: not found",name);return;}
    if(*hf2){jlog(@"%s: already hooked",name);return;}
    MSHookFunction(fa,hf,of);
    *hf2=YES;
    jlog(@"%s: OK at %p orig=%p",name,fa,*of);
}

static void applyAllHooks(void){if(!g_fLimitDmg)findIL2CPP();hookOneFunc(g_fLimitDmg,hLimitDmg,(void**)&g_oLimitDmg,&g_hLimitDmg,"limitDmg");jlog(@"applyAllHooks done");}

// ===== UI =====
static UIView *g_panel=nil, *g_titleBar=nil;
static UIScrollView *g_scrollView=nil;
static UIButton *g_btnIgnoreUnlock=nil,*g_btnExSkillNoCD=nil,*g_btnGodMode=nil,*g_btnFullScreen=nil,*g_btnSkillReplace=nil;
static UIButton *g_btnRepS1=nil,*g_btnRepS2=nil,*g_btnRepS3=nil,*g_btnRepS4=nil,*g_btnRepS5=nil;
static UIButton *g_btnApplySkin=nil,*g_btnApplyWeapon=nil,*g_btnApplyHalo=nil,*g_btnScanSkin=nil;
static UIButton *g_btnVacuum=nil; // v114
static UIButton *g_btnAntiReport=nil; // v114
static UIButton *g_btnNoAds=nil; // v116
static UIButton *g_btnMonsterFreeze=nil; // v118: 怪不动
static UIButton *g_btnAttackRangePlus=nil; // v118: 攻击范围+
static UISlider *g_slider=nil,*g_skinSlider=nil,*g_weaponSlider=nil,*g_haloSlider=nil,*g_speedSlider=nil,*g_dmgMultiSlider=nil;
static UILabel *g_sliderLabel=nil,*g_skinLabel=nil,*g_weaponLabel=nil,*g_haloLabel=nil,*g_speedLabel=nil,*g_dmgMultiLabel=nil;
static BOOL g_panelOpen=NO;
static CGFloat g_panelW=360, g_panelH=1000;
static UIView *g_resizeHandle=nil, *g_resizeHandleTop=nil;

#define IMGUI_BG [UIColor colorWithRed:0.09 green:0.09 blue:0.12 alpha:0.96]
#define IMGUI_TITLE_BG [UIColor colorWithRed:0.04 green:0.04 blue:0.06 alpha:1.0]
#define IMGUI_ACCENT [UIColor colorWithRed:0.40 green:0.68 blue:1.00 alpha:1.0]
#define IMGUI_GREEN [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0]
#define IMGUI_RED [UIColor colorWithRed:0.78 green:0.20 blue:0.20 alpha:1.0]
#define IMGUI_TEXT [UIColor colorWithRed:0.90 green:0.90 blue:0.92 alpha:1.0]
#define IMGUI_DIMTEXT [UIColor colorWithRed:0.55 green:0.55 blue:0.60 alpha:1.0]
#define IMGUI_BALL_BG [UIColor colorWithRed:0.12 green:0.28 blue:0.58 alpha:0.92]
#define IMGUI_BTN_ON [UIColor colorWithRed:0.16 green:0.52 blue:0.28 alpha:0.95]
#define IMGUI_BTN_OFF [UIColor colorWithRed:0.52 green:0.14 blue:0.14 alpha:0.95]
#define IMGUI_BORDER [UIColor colorWithRed:0.25 green:0.25 blue:0.30 alpha:0.8]

@interface JYJHActionHandler:NSObject
+(instancetype)shared;
-(void)onIgnoreUnlock;-(void)onExSkillNoCD;-(void)onGodMode;-(void)onFullScreen;-(void)onSkillReplace;
-(void)onReplaceS1;-(void)onReplaceS2;-(void)onReplaceS3;-(void)onReplaceS4;-(void)onReplaceS5;
-(void)speedSliderChanged:(UISlider*)s;
-(void)onApplySkin;-(void)onApplyWeapon;-(void)onApplyHalo;
-(void)sliderChanged:(UISlider*)s;-(void)skinSliderChanged:(UISlider*)s;-(void)weaponSliderChanged:(UISlider*)s;-(void)haloSliderChanged:(UISlider*)s;
-(void)dmgMultiChanged:(UISlider*)s;
-(void)onDumpSkinIds;
-(void)onVacuum; // v114
-(void)vacuumTickFire:(NSTimer*)t; // v114 timer callback
-(void)onAntiReport; // v114
-(void)onNoAds; // v117: 免广告
-(void)onMonsterFreeze; // v118: 怪不动
-(void)onAttackRangePlus; // v118: 攻击范围+
@end

static UIButton* mkBtn(CGRect f,SEL a){
    UIButton *b=[UIButton buttonWithType:UIButtonTypeCustom];
    b.frame=f;b.layer.cornerRadius=4;b.layer.borderWidth=1;b.layer.borderColor=IMGUI_BORDER.CGColor;
    b.titleLabel.font=[UIFont boldSystemFontOfSize:13];b.titleLabel.textColor=IMGUI_TEXT;
    [b addTarget:[JYJHActionHandler shared] action:a forControlEvents:UIControlEventTouchUpInside];
    return b;
}

static void refreshBtns(void){
    if(g_ignoreUnlock){[g_btnIgnoreUnlock setTitle:@"ON  忽略解锁" forState:UIControlStateNormal];g_btnIgnoreUnlock.backgroundColor=IMGUI_BTN_ON;g_btnIgnoreUnlock.layer.borderColor=IMGUI_GREEN.CGColor;}
    else{[g_btnIgnoreUnlock setTitle:@"OFF 忽略解锁" forState:UIControlStateNormal];g_btnIgnoreUnlock.backgroundColor=IMGUI_BTN_OFF;g_btnIgnoreUnlock.layer.borderColor=IMGUI_RED.CGColor;}
    if(g_exSkillNoCD){[g_btnExSkillNoCD setTitle:@"ON  技能无CD" forState:UIControlStateNormal];g_btnExSkillNoCD.backgroundColor=IMGUI_BTN_ON;g_btnExSkillNoCD.layer.borderColor=IMGUI_GREEN.CGColor;}
    else{[g_btnExSkillNoCD setTitle:@"OFF 技能无CD" forState:UIControlStateNormal];g_btnExSkillNoCD.backgroundColor=IMGUI_BTN_OFF;g_btnExSkillNoCD.layer.borderColor=IMGUI_RED.CGColor;}
    if(g_godMode){[g_btnGodMode setTitle:@"ON  玩家不死" forState:UIControlStateNormal];g_btnGodMode.backgroundColor=IMGUI_BTN_ON;g_btnGodMode.layer.borderColor=IMGUI_GREEN.CGColor;}
    else{[g_btnGodMode setTitle:@"OFF 玩家不死" forState:UIControlStateNormal];g_btnGodMode.backgroundColor=IMGUI_BTN_OFF;g_btnGodMode.layer.borderColor=IMGUI_RED.CGColor;}
    if(g_fullScreen){[g_btnFullScreen setTitle:@"ON  全屏秒杀" forState:UIControlStateNormal];g_btnFullScreen.backgroundColor=IMGUI_BTN_ON;g_btnFullScreen.layer.borderColor=IMGUI_GREEN.CGColor;}
    else{[g_btnFullScreen setTitle:@"OFF 全屏秒杀" forState:UIControlStateNormal];g_btnFullScreen.backgroundColor=IMGUI_BTN_OFF;g_btnFullScreen.layer.borderColor=IMGUI_RED.CGColor;}
    if(g_skillReplace){[g_btnSkillReplace setTitle:@"ON  技能替换" forState:UIControlStateNormal];g_btnSkillReplace.backgroundColor=IMGUI_BTN_ON;g_btnSkillReplace.layer.borderColor=IMGUI_GREEN.CGColor;}
    else{[g_btnSkillReplace setTitle:@"OFF 技能替换" forState:UIControlStateNormal];g_btnSkillReplace.backgroundColor=IMGUI_BTN_OFF;g_btnSkillReplace.layer.borderColor=IMGUI_RED.CGColor;}
    if(g_replaceSkill1){[g_btnRepS1 setTitle:@"1→大" forState:UIControlStateNormal];g_btnRepS1.backgroundColor=IMGUI_BTN_ON;g_btnRepS1.layer.borderColor=IMGUI_GREEN.CGColor;}
    else{[g_btnRepS1 setTitle:@"1" forState:UIControlStateNormal];g_btnRepS1.backgroundColor=[UIColor colorWithRed:0.15 green:0.15 blue:0.18 alpha:0.95];g_btnRepS1.layer.borderColor=IMGUI_BORDER.CGColor;}
    if(g_replaceSkill2){[g_btnRepS2 setTitle:@"2→大" forState:UIControlStateNormal];g_btnRepS2.backgroundColor=IMGUI_BTN_ON;g_btnRepS2.layer.borderColor=IMGUI_GREEN.CGColor;}
    else{[g_btnRepS2 setTitle:@"2" forState:UIControlStateNormal];g_btnRepS2.backgroundColor=[UIColor colorWithRed:0.15 green:0.15 blue:0.18 alpha:0.95];g_btnRepS2.layer.borderColor=IMGUI_BORDER.CGColor;}
    if(g_replaceSkill3){[g_btnRepS3 setTitle:@"3→大" forState:UIControlStateNormal];g_btnRepS3.backgroundColor=IMGUI_BTN_ON;g_btnRepS3.layer.borderColor=IMGUI_GREEN.CGColor;}
    else{[g_btnRepS3 setTitle:@"3" forState:UIControlStateNormal];g_btnRepS3.backgroundColor=[UIColor colorWithRed:0.15 green:0.15 blue:0.18 alpha:0.95];g_btnRepS3.layer.borderColor=IMGUI_BORDER.CGColor;}
    if(g_replaceSkill4){[g_btnRepS4 setTitle:@"4→大" forState:UIControlStateNormal];g_btnRepS4.backgroundColor=IMGUI_BTN_ON;g_btnRepS4.layer.borderColor=IMGUI_GREEN.CGColor;}
    else{[g_btnRepS4 setTitle:@"4" forState:UIControlStateNormal];g_btnRepS4.backgroundColor=[UIColor colorWithRed:0.15 green:0.15 blue:0.18 alpha:0.95];g_btnRepS4.layer.borderColor=IMGUI_BORDER.CGColor;}
    if(g_replaceSkill5){[g_btnRepS5 setTitle:@"5→大" forState:UIControlStateNormal];g_btnRepS5.backgroundColor=IMGUI_BTN_ON;g_btnRepS5.layer.borderColor=IMGUI_GREEN.CGColor;}
    else{[g_btnRepS5 setTitle:@"5" forState:UIControlStateNormal];g_btnRepS5.backgroundColor=[UIColor colorWithRed:0.15 green:0.15 blue:0.18 alpha:0.95];g_btnRepS5.layer.borderColor=IMGUI_BORDER.CGColor;}
    // 皮肤按钮
    if(g_btnApplySkin){
        if(g_appliedSkinId>0){[g_btnApplySkin setTitle:[NSString stringWithFormat:@"皮肤:%d(已应用)",g_appliedSkinId] forState:UIControlStateNormal];g_btnApplySkin.backgroundColor=IMGUI_BTN_ON;g_btnApplySkin.layer.borderColor=IMGUI_GREEN.CGColor;}
        else if(g_skinIdsLoaded){[g_btnApplySkin setTitle:@"应用皮肤" forState:UIControlStateNormal];g_btnApplySkin.backgroundColor=[UIColor colorWithRed:0.18 green:0.35 blue:0.55 alpha:0.95];g_btnApplySkin.layer.borderColor=IMGUI_ACCENT.CGColor;}
        else{[g_btnApplySkin setTitle:@"先扫描" forState:UIControlStateNormal];g_btnApplySkin.backgroundColor=[UIColor colorWithRed:0.35 green:0.14 blue:0.14 alpha:0.95];g_btnApplySkin.layer.borderColor=IMGUI_RED.CGColor;}
    }
    if(g_btnApplyWeapon){
        if(g_appliedWeaponId>0){[g_btnApplyWeapon setTitle:[NSString stringWithFormat:@"武器:%d(已应用)",g_appliedWeaponId] forState:UIControlStateNormal];g_btnApplyWeapon.backgroundColor=IMGUI_BTN_ON;g_btnApplyWeapon.layer.borderColor=IMGUI_GREEN.CGColor;}
        else if(g_skinIdsLoaded){[g_btnApplyWeapon setTitle:@"应用武器" forState:UIControlStateNormal];g_btnApplyWeapon.backgroundColor=[UIColor colorWithRed:0.18 green:0.35 blue:0.55 alpha:0.95];g_btnApplyWeapon.layer.borderColor=IMGUI_ACCENT.CGColor;}
        else{[g_btnApplyWeapon setTitle:@"先扫描" forState:UIControlStateNormal];g_btnApplyWeapon.backgroundColor=[UIColor colorWithRed:0.35 green:0.14 blue:0.14 alpha:0.95];g_btnApplyWeapon.layer.borderColor=IMGUI_RED.CGColor;}
    }
    if(g_btnApplyHalo){
        if(g_appliedHaloId>0){[g_btnApplyHalo setTitle:[NSString stringWithFormat:@"光环:%d(已应用)",g_appliedHaloId] forState:UIControlStateNormal];g_btnApplyHalo.backgroundColor=IMGUI_BTN_ON;g_btnApplyHalo.layer.borderColor=IMGUI_GREEN.CGColor;}
        else if(g_skinIdsLoaded){[g_btnApplyHalo setTitle:@"应用光环" forState:UIControlStateNormal];g_btnApplyHalo.backgroundColor=[UIColor colorWithRed:0.18 green:0.35 blue:0.55 alpha:0.95];g_btnApplyHalo.layer.borderColor=IMGUI_ACCENT.CGColor;}
        else{[g_btnApplyHalo setTitle:@"先扫描" forState:UIControlStateNormal];g_btnApplyHalo.backgroundColor=[UIColor colorWithRed:0.35 green:0.14 blue:0.14 alpha:0.95];g_btnApplyHalo.layer.borderColor=IMGUI_RED.CGColor;}
    }
    if(g_btnScanSkin){
        if(g_skinIdsLoaded){[g_btnScanSkin setTitle:[NSString stringWithFormat:@"已扫描:皮肤%d/武器%d/光环%d",g_roleSkinCount,g_weaponSkinCount,g_haloSkinCount] forState:UIControlStateNormal];g_btnScanSkin.backgroundColor=[UIColor colorWithRed:0.16 green:0.52 blue:0.28 alpha:0.95];}
        else{[g_btnScanSkin setTitle:@"扫描皮肤ID" forState:UIControlStateNormal];g_btnScanSkin.backgroundColor=[UIColor colorWithRed:0.18 green:0.35 blue:0.55 alpha:0.95];}
        g_btnScanSkin.layer.borderColor=IMGUI_ACCENT.CGColor;
    }
    // v114: 吸怪按钮
    if(g_btnVacuum){
        if(g_vacuumMode){[g_btnVacuum setTitle:@"ON  吸怪" forState:UIControlStateNormal];g_btnVacuum.backgroundColor=IMGUI_BTN_ON;g_btnVacuum.layer.borderColor=IMGUI_GREEN.CGColor;}
        else{[g_btnVacuum setTitle:@"OFF 吸怪" forState:UIControlStateNormal];g_btnVacuum.backgroundColor=IMGUI_BTN_OFF;g_btnVacuum.layer.borderColor=IMGUI_RED.CGColor;}
    }
    // v114: 反上报按钮
    if(g_btnAntiReport){
        if(g_antiReport){[g_btnAntiReport setTitle:@"ON  反上报" forState:UIControlStateNormal];g_btnAntiReport.backgroundColor=IMGUI_BTN_ON;g_btnAntiReport.layer.borderColor=IMGUI_GREEN.CGColor;}
        else{[g_btnAntiReport setTitle:@"OFF 反上报" forState:UIControlStateNormal];g_btnAntiReport.backgroundColor=IMGUI_BTN_OFF;g_btnAntiReport.layer.borderColor=IMGUI_RED.CGColor;}
    }
    // v116: 免广告按钮
    if(g_btnNoAds){
        if(g_noAds){[g_btnNoAds setTitle:@"ON  免广告" forState:UIControlStateNormal];g_btnNoAds.backgroundColor=IMGUI_BTN_ON;g_btnNoAds.layer.borderColor=IMGUI_GREEN.CGColor;}
        else{[g_btnNoAds setTitle:@"OFF 免广告" forState:UIControlStateNormal];g_btnNoAds.backgroundColor=IMGUI_BTN_OFF;g_btnNoAds.layer.borderColor=IMGUI_RED.CGColor;}
    }
    // v118: 怪不动按钮
    if(g_btnMonsterFreeze){
        if(g_monsterFreeze){[g_btnMonsterFreeze setTitle:@"ON  怪不动" forState:UIControlStateNormal];g_btnMonsterFreeze.backgroundColor=IMGUI_BTN_ON;g_btnMonsterFreeze.layer.borderColor=IMGUI_GREEN.CGColor;}
        else{[g_btnMonsterFreeze setTitle:@"OFF 怪不动" forState:UIControlStateNormal];g_btnMonsterFreeze.backgroundColor=IMGUI_BTN_OFF;g_btnMonsterFreeze.layer.borderColor=IMGUI_RED.CGColor;}
    }
    // v118: 攻击范围+按钮
    if(g_btnAttackRangePlus){
        if(g_attackRangePlus){[g_btnAttackRangePlus setTitle:@"ON  攻击范围+" forState:UIControlStateNormal];g_btnAttackRangePlus.backgroundColor=IMGUI_BTN_ON;g_btnAttackRangePlus.layer.borderColor=IMGUI_GREEN.CGColor;}
        else{[g_btnAttackRangePlus setTitle:@"OFF 攻击范围+" forState:UIControlStateNormal];g_btnAttackRangePlus.backgroundColor=IMGUI_BTN_OFF;g_btnAttackRangePlus.layer.borderColor=IMGUI_RED.CGColor;}
    }
}

static void layoutPanelCenter(void){if(!g_panel)return;CGRect sc=[UIScreen mainScreen].bounds;CGFloat px=(sc.size.width-g_panelW)/2;g_panel.frame=CGRectMake(px,80,g_panelW,g_panelH);}

static void togglePanel(void){
    g_panelOpen=!g_panelOpen;g_panel.hidden=!g_panelOpen;
    g_resizeHandle.hidden=!g_panelOpen;
    g_resizeHandleTop.hidden=!g_panelOpen;
    if(g_panelOpen){
        layoutPanelCenter();
        CGRect f=g_panel.frame;
        if(g_resizeHandle) g_resizeHandle.frame=CGRectMake(f.origin.x+g_panelW-36,f.origin.y+g_panelH-36,36,36);
        if(g_resizeHandleTop) g_resizeHandleTop.frame=CGRectMake(f.origin.x+g_panelW-36,f.origin.y,36,36);
    }
}

static void applyPartChange(void) {
    jlog(@"applyPart: skin=%d weapon=%d halo=%d data=%p", g_appliedSkinId, g_appliedWeaponId, g_appliedHaloId, g_lobbyActorData);
    
    if(!g_lobbyActorData) {
        jlog(@"applyPart: no LobbyActorData yet, will apply on next SetSecneData call");
        return;
    }
    
    BOOL isSelf = NO;
    memcpy(&isSelf, (uint8_t*)g_lobbyActorData + 0x2b, 1);
    if(!isSelf) { jlog(@"applyPart: IsSelf=NO, skip"); return; }
    
    void *sceneData = NULL;
    memcpy(&sceneData, (uint8_t*)g_lobbyActorData + 0x10, 8);
    if(isValidPtr(sceneData)) {
        if(g_appliedSkinId > 0) memcpy((uint8_t*)sceneData + 0x40, &g_appliedSkinId, 4);
        if(g_appliedWeaponId > 0) memcpy((uint8_t*)sceneData + 0x44, &g_appliedWeaponId, 4);
        jlog(@"applyPart: wrote to mSceneData directly");
    } else {
        jlog(@"applyPart: mSceneData invalid, will apply on next SetSecneData call");
    }
    
    BOOL yes = YES;
    memcpy((uint8_t*)g_lobbyActorData + 0x28, &yes, 1);
    jlog(@"applyPart: set NeedUpdatePart=true");
}

@implementation JYJHActionHandler
+(instancetype)shared{static JYJHActionHandler *s;static dispatch_once_t o;dispatch_once(&o,^{s=[[self alloc]init];});return s;}
-(void)onIgnoreUnlock{
    g_ignoreUnlock=!g_ignoreUnlock;
    if(g_ignoreUnlock&&!g_hUnlock){findIL2CPP();hookOneFunc(g_fUnlock,hUnlock,(void**)&g_oUnlock,&g_hUnlock,"Unlock");}
    refreshBtns();
}
-(void)onExSkillNoCD{
    g_exSkillNoCD=!g_exSkillNoCD;
    if(g_exSkillNoCD){findIL2CPP();
        if(!g_hIsReady)hookOneFunc(g_fIsReady,hIsReady,(void**)&g_oIsReady,&g_hIsReady,"IsReady");
        if(!g_hAttackCanUse)hookOneFunc(g_fAttackCanUse,hAttackCanUse,(void**)&g_oAttackCanUse,&g_hAttackCanUse,"AttackCanUse");
    }
    refreshBtns();
}
-(void)onGodMode{
    g_godMode=!g_godMode;
    if(g_godMode){findIL2CPP();
        if(!g_hAttackCanUse)hookOneFunc(g_fAttackCanUse,hAttackCanUse,(void**)&g_oAttackCanUse,&g_hAttackCanUse,"AttackCanUse");
        if(!g_hIsReady)hookOneFunc(g_fIsReady,hIsReady,(void**)&g_oIsReady,&g_hIsReady,"IsReady");
        if(!g_hCanBeAttack)hookOneFunc(g_fCanBeAttack,hCanBeAttack,(void**)&g_oCanBeAttack,&g_hCanBeAttack,"CanBeAttack");
        if(!g_hDamage)hookOneFunc(g_fDamage,hDamage,(void**)&g_oDamage,&g_hDamage,"Damage");
        // v114: hook ChangeCharacterToDead
        if(g_fChangeCharacterToDead && !g_hChangeCharacterToDead) hookOneFunc(g_fChangeCharacterToDead, hChangeCharacterToDead, (void**)&g_oChangeCharacterToDead, &g_hChangeCharacterToDead, "ChangeCharacterToDead");
    }
    refreshBtns();
}
-(void)onFullScreen{
    g_fullScreen=!g_fullScreen;
    if(g_fullScreen){findIL2CPP();
        if(!g_hIntersects)hookOneFunc(g_fIntersects,hIntersects,(void**)&g_oIntersects,&g_hIntersects,"Intersects");
        if(!g_hCheckHit)hookOneFunc(g_fCheckHit,hCheckHit,(void**)&g_oCheckHit,&g_hCheckHit,"CheckHit");
        if(!g_hDamage)hookOneFunc(g_fDamage,hDamage,(void**)&g_oDamage,&g_hDamage,"Damage");
        if(!g_hHitSystemUpdate)hookOneFunc(g_fHitSystemUpdate,hHitSystemUpdate,(void**)&g_oHitSystemUpdate,&g_hHitSystemUpdate,"HitSystem.Update");
        g_enemyCount=0;
    }
    refreshBtns();
}
-(void)onSkillReplace{
    g_skillReplace=!g_skillReplace;
    if(g_skillReplace){findIL2CPP();
        if(!g_hUseSkill)hookOneFunc(g_fUseSkill,hUseSkill,(void**)&g_oUseSkill,&g_hUseSkill,"UseSkill");
        if(!g_hUpdateSkillCD)hookOneFunc(g_fUpdateSkillCD,hUpdateSkillCD,(void**)&g_oUpdateSkillCD,&g_hUpdateSkillCD,"UpdateSkillCD");
        if(!g_hIsReady)hookOneFunc(g_fIsReady,hIsReady,(void**)&g_oIsReady,&g_hIsReady,"IsReady");
        if(!g_hAttackCanUse)hookOneFunc(g_fAttackCanUse,hAttackCanUse,(void**)&g_oAttackCanUse,&g_hAttackCanUse,"AttackCanUse");
        if(!g_hDamage)hookOneFunc(g_fDamage,hDamage,(void**)&g_oDamage,&g_hDamage,"Damage");
    }
    refreshBtns();
}
-(void)onReplaceS1{g_replaceSkill1=!g_replaceSkill1;if(g_replaceSkill1&&!g_skillReplace){g_skillReplace=YES;[self onSkillReplace];}refreshBtns();}
-(void)onReplaceS2{g_replaceSkill2=!g_replaceSkill2;if(g_replaceSkill2&&!g_skillReplace){g_skillReplace=YES;[self onSkillReplace];}refreshBtns();}
-(void)onReplaceS3{g_replaceSkill3=!g_replaceSkill3;if(g_replaceSkill3&&!g_skillReplace){g_skillReplace=YES;[self onSkillReplace];}refreshBtns();}
-(void)onReplaceS4{g_replaceSkill4=!g_replaceSkill4;if(g_replaceSkill4&&!g_skillReplace){g_skillReplace=YES;[self onSkillReplace];}refreshBtns();}
-(void)onReplaceS5{g_replaceSkill5=!g_replaceSkill5;if(g_replaceSkill5&&!g_skillReplace){g_skillReplace=YES;[self onSkillReplace];}refreshBtns();}
-(void)speedSliderChanged:(UISlider*)s{
    g_speedMul=s.value;
    if(g_speedMul>1.0f && !g_hMoveStep) { findIL2CPP(); if(!g_hMoveStep) hookOneFunc(g_fMoveStep,hMoveStep,(void**)&g_oMoveStep,&g_hMoveStep,"MoveStep"); }
    g_speedLabel.text=[NSString stringWithFormat:@"移动速度: %.1fx",g_speedMul];
}
-(void)dmgMultiChanged:(UISlider*)s{
    g_damageMulti=(int)roundf(s.value); if(g_damageMulti<1) g_damageMulti=1;
    g_dmgMultiLabel.text=[NSString stringWithFormat:@"伤害倍数: ×%d",g_damageMulti];
    if(g_damageMulti>1 && !g_hDamage) { findIL2CPP(); if(!g_hDamage) hookOneFunc(g_fDamage,hDamage,(void**)&g_oDamage,&g_hDamage,"Damage"); }
}
-(void)sliderChanged:(UISlider*)s{
    g_damageLimit=(int)s.value;
    g_sliderLabel.text=[NSString stringWithFormat:@"伤害上限: %d",g_damageLimit];
    if(!g_hLimitDmg){findIL2CPP();hookOneFunc(g_fLimitDmg,hLimitDmg,(void**)&g_oLimitDmg,&g_hLimitDmg,"limitDmg");}
}
-(void)skinSliderChanged:(UISlider*)s{
    int idx=(int)s.value;
    if(g_skinIdsLoaded){if(idx<0)idx=0;if(idx>=g_roleSkinCount)idx=g_roleSkinCount-1;g_skinId=g_roleSkinIds[idx];}
    else g_skinId=idx;
    g_skinLabel.text=[NSString stringWithFormat:@"皮肤ID: %d",g_skinId];
}
-(void)weaponSliderChanged:(UISlider*)s{
    int idx=(int)s.value;
    if(g_skinIdsLoaded){if(idx<0)idx=0;if(idx>=g_weaponSkinCount)idx=g_weaponSkinCount-1;g_weaponId=g_weaponSkinIds[idx];}
    else g_weaponId=idx;
    g_weaponLabel.text=[NSString stringWithFormat:@"武器ID: %d",g_weaponId];
}
-(void)haloSliderChanged:(UISlider*)s{
    int idx=(int)s.value;
    if(g_skinIdsLoaded){if(idx<0)idx=0;if(idx>=g_haloSkinCount)idx=g_haloSkinCount-1;g_haloId=g_haloSkinIds[idx];}
    else g_haloId=idx;
    g_haloLabel.text=[NSString stringWithFormat:@"光环ID: %d",g_haloId];
}
-(void)ensureSkinHooksActive {
    findIL2CPP();
    if(g_fSetSecneData && !g_hSetSecneData) hookOneFunc(g_fSetSecneData, hSetSecneData, (void**)&g_oSetSecneData, &g_hSetSecneData, "SetSecneData");
}
-(void)onApplySkin{
    if(!g_skinIdsLoaded){jlog(@"ApplySkin: scan first");return;}
    [self ensureSkinHooksActive];
    g_appliedSkinId = g_skinId;
    jlog(@"ApplySkin: skin=%d", g_skinId);
    applyPartChange();
    refreshBtns();
}
-(void)onApplyWeapon{
    if(!g_skinIdsLoaded){jlog(@"ApplyWeapon: scan first");return;}
    [self ensureSkinHooksActive];
    g_appliedWeaponId = g_weaponId;
    jlog(@"ApplyWeapon: weapon=%d", g_weaponId);
    applyPartChange();
    refreshBtns();
}
-(void)onApplyHalo{
    if(!g_skinIdsLoaded){jlog(@"ApplyHalo: scan first");return;}
    [self ensureSkinHooksActive];
    g_appliedHaloId = g_haloId;
    jlog(@"ApplyHalo: halo=%d", g_haloId);
    applyPartChange();
    refreshBtns();
}
-(void)onDumpSkinIds{
    if(!g_classUnityGameEntry&&!g_classHotfixGameEntry){findIL2CPP();}
    if(g_skinIdsLoaded){refreshBtns();return;}
    scanSkinIds(); refreshBtns();
}
// v115: 真正的吸怪 — hook Move获取Transform2D*, 定时器修改Position.X
-(void)onVacuum{
    g_vacuumMode=!g_vacuumMode;
    if(g_vacuumMode){
        findIL2CPP();
        // hook Move方法获取Transform2D*指针
        if(g_fMove && !g_hMove) hookOneFunc(g_fMove, hMove, (void**)&g_oMove, &g_hMove, "Move(vacuum)");
        if(!g_hMove) jlog(@"vacuum: WARNING - Move method not found/hooked!");
        // 也hook CanBeAttack和Damage来追踪敌人
        if(!g_hCanBeAttack)hookOneFunc(g_fCanBeAttack,hCanBeAttack,(void**)&g_oCanBeAttack,&g_hCanBeAttack,"CanBeAttack");
        if(!g_hDamage)hookOneFunc(g_fDamage,hDamage,(void**)&g_oDamage,&g_hDamage,"Damage");
        g_enemyCount=0;
        g_playerTransform2D=NULL;
        startVacuumTimer();
        jlog(@"vacuum: ON - hooking Move for Transform2D*");
    } else {
        stopVacuumTimer();
        g_playerTransform2D=NULL;
        jlog(@"vacuum: OFF");
    }
    refreshBtns();
}
-(void)vacuumTickFire:(NSTimer*)t {
    vacuumTick(t);
}

// v115: 反上报 — 屏蔽飞书webhook上报
// 策略: 多层拦截
// 1. hook NSURLRequest initWithURL: — 拦截请求创建
// 2. hook NSMutableURLRequest setURL: — 拦截URL修改
// 3. hook NSURLSession dataTaskWithRequest:completionHandler: — 拦截CFNetwork层发送
static IMP g_origInitWithURL=0;
static IMP g_origInitWithURLCachePolicy=0;
static IMP g_origSetURL=0;
static IMP g_origDataTaskWithRequest=0;

static BOOL isBlockedURL(NSURL *url) {
    if(!g_antiReport) return NO;
    if(!url || !url.host) return NO;
    return [url.host containsString:@"feishu.cn"];
}

// Hook NSMutableURLRequest setURL: — 任何setURL都会被拦截
static void hookedSetURL(id self, SEL _cmd, NSURL *url) {
    if(isBlockedURL(url)) {
        jlog(@"antiReport: BLOCKED setURL to %@", url);
        url = [NSURL URLWithString:@"about:blank"];
    }
    if(g_origSetURL) {
        typedef void (*Fn)(id,SEL,NSURL*);
        ((Fn)g_origSetURL)(self, _cmd, url);
    }
}

// Hook NSURLRequest initWithURL:
static id hookedInitWithURL(id self, SEL _cmd, NSURL *url) {
    if(isBlockedURL(url)) {
        jlog(@"antiReport: BLOCKED initWithURL to %@", url);
        url = [NSURL URLWithString:@"about:blank"];
    }
    if(g_origInitWithURL) {
        typedef id (*Fn)(id,SEL,NSURL*);
        return ((Fn)g_origInitWithURL)(self, _cmd, url);
    }
    return self;
}

// Hook NSURLRequest initWithURL:cachePolicy:timeoutInterval:
static id hookedInitWithURLCache(id self, SEL _cmd, NSURL *url, NSURLRequestCachePolicy policy, NSTimeInterval timeout) {
    if(isBlockedURL(url)) {
        jlog(@"antiReport: BLOCKED initWithURL:cachePolicy to %@", url);
        url = [NSURL URLWithString:@"about:blank"];
    }
    if(g_origInitWithURLCachePolicy) {
        typedef id (*Fn)(id,SEL,NSURL*,NSURLRequestCachePolicy,NSTimeInterval);
        return ((Fn)g_origInitWithURLCachePolicy)(self, _cmd, url, policy, timeout);
    }
    return self;
}

// v115: Hook NSURLSession dataTaskWithRequest:completionHandler: — 拦截CFNetwork层
static NSURLSessionDataTask* hookedDataTaskWithRequest(id self, SEL _cmd, NSURLRequest *request, void(^completionHandler)(NSData*, NSURLResponse*, NSError*)) {
    if(g_antiReport && request && request.URL && [request.URL.host containsString:@"feishu.cn"]) {
        jlog(@"antiReport: BLOCKED dataTask to %@", request.URL);
        // 返回一个空task, 不实际发送请求
        NSURLRequest *blankReq = [NSURLRequest requestWithURL:[NSURL URLWithString:@"about:blank"]];
        if(g_origDataTaskWithRequest) {
            typedef NSURLSessionDataTask* (*Fn)(id,SEL,NSURLRequest*,void(^)(NSData*,NSURLResponse*,NSError*));
            return ((Fn)g_origDataTaskWithRequest)(self, _cmd, blankReq, completionHandler);
        }
        return nil;
    }
    if(g_origDataTaskWithRequest) {
        typedef NSURLSessionDataTask* (*Fn)(id,SEL,NSURLRequest*,void(^)(NSData*,NSURLResponse*,NSError*));
        return ((Fn)g_origDataTaskWithRequest)(self, _cmd, request, completionHandler);
    }
    return nil;
}

-(void)onAntiReport {
    g_antiReport=!g_antiReport;
    if(g_antiReport) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            // Hook NSMutableURLRequest setURL: — 任何setURL都会被拦截
            Class mutableReqClass = [NSMutableURLRequest class];
            SEL setURLSel = @selector(setURL:);
            Method setURLM = class_getInstanceMethod(mutableReqClass, setURLSel);
            if(setURLM) {
                g_origSetURL = method_setImplementation(setURLM, (IMP)hookedSetURL);
                jlog(@"antiReport: hooked NSMutableURLRequest setURL:");
            }
            // Hook NSURLRequest initWithURL:
            Class reqClass = [NSURLRequest class];
            SEL initSel = @selector(initWithURL:);
            Method initM = class_getInstanceMethod(reqClass, initSel);
            if(initM) {
                g_origInitWithURL = method_setImplementation(initM, (IMP)hookedInitWithURL);
                jlog(@"antiReport: hooked NSURLRequest initWithURL:");
            }
            // Hook NSURLRequest initWithURL:cachePolicy:timeoutInterval:
            SEL initCacheSel = @selector(initWithURL:cachePolicy:timeoutInterval:);
            Method initCacheM = class_getInstanceMethod(reqClass, initCacheSel);
            if(initCacheM) {
                g_origInitWithURLCachePolicy = method_setImplementation(initCacheM, (IMP)hookedInitWithURLCache);
                jlog(@"antiReport: hooked NSURLRequest initWithURL:cachePolicy:timeoutInterval:");
            }
            // v115: Hook NSURLSession dataTaskWithRequest:completionHandler: — 拦截CFNetwork层
            Class sessionClass = [NSURLSession class];
            SEL dataTaskSel = @selector(dataTaskWithRequest:completionHandler:);
            Method dataTaskM = class_getInstanceMethod(sessionClass, dataTaskSel);
            if(dataTaskM) {
                g_origDataTaskWithRequest = method_setImplementation(dataTaskM, (IMP)hookedDataTaskWithRequest);
                jlog(@"antiReport: hooked NSURLSession dataTaskWithRequest:completionHandler:");
            }
        });
    }
    jlog(@"antiReport: %d", g_antiReport);
    refreshBtns();
}

// v116: 免广告 — 模拟月卡效果
// 策略:
// v117: 免广告 — 三管齐下
//   1. Hook ShowVideo直接跳过 → 不播放广告
//   2. Hook IsAdAvailable返回false → 隐藏广告按钮
//   3. 修改AdsHelper单例字段(AdsEnable=false, InAdsPlaying=false) → 禁止广告播放
-(void)onNoAds {
    g_noAds=!g_noAds;
    if(g_noAds) {
        findIL2CPP();
        
        // v117策略1: Hook ShowVideo — 直接跳过广告播放
        // AdsHelper.ShowVideo(int adId, string adUnitId, bool multiton, bool isShow, bool isCardJump)
        // C#实例方法, MSHookFunction可能传mi → 6参数hook(mi,self,adId,adUnitId,multiton,isShow,isCardJump)
        // 原函数指针5参数(self,adId,adUnitId,multiton,isShow,isCardJump)
        if(g_fShowVideo && !g_hShowVideo) {
            hookOneFunc(g_fShowVideo, hShowVideo, (void**)&g_oShowVideo, &g_hShowVideo, "ShowVideo(noAds)");
        }
        
        // v117策略2: Hook IsAdAvailable返回false
        if(g_fIsAdAvailable && !g_hIsAdAvailable) {
            hookOneFunc(g_fIsAdAvailable, hIsAdAvailable, (void**)&g_oIsAdAvailable, &g_hIsAdAvailable, "IsAdAvailable");
        }
        
        jlog(@"noAds: ON - ShowVideo hooked=%d, IsAdAvailable hooked=%d", g_hShowVideo, g_hIsAdAvailable);
    } else {
        jlog(@"noAds: OFF");
    }
    refreshBtns();
}

// v120: 怪不动 — hook AIAgent.Update只冻结敌方
-(void)onMonsterFreeze {
    g_monsterFreeze=!g_monsterFreeze;
    if(g_monsterFreeze) {
        findIL2CPP();
        // v120方案: hook AIAgent.Update — 只冻结敌方AI, 玩家正常(自动战斗不受影响)
        if(g_fAIAgentUpdate && !g_hAIAgentUpdate) {
            hookOneFunc(g_fAIAgentUpdate, hAIAgentUpdate, (void**)&g_oAIAgentUpdate, &g_hAIAgentUpdate, "AIAgent.Update");
        }
        jlog(@"monsterFreeze: ON - AIAgent.Update hooked=%d (addr=%p)", g_hAIAgentUpdate, g_fAIAgentUpdate);
    } else {
        jlog(@"monsterFreeze: OFF (hook remains but passes through)");
    }
    refreshBtns();
}

// v118: 攻击范围+ — 扩大HitSystem的碰撞检测范围
-(void)onAttackRangePlus {
    g_attackRangePlus=!g_attackRangePlus;
    if(g_attackRangePlus) {
        findIL2CPP();
        // Hook HitSystem.Update来扩大collBound.Extents
        if(!g_hHitSystemUpdate) hookOneFunc(g_fHitSystemUpdate, hHitSystemUpdate, (void**)&g_oHitSystemUpdate, &g_hHitSystemUpdate, "HitSystem.Update");
        // 也hook Intersects和CheckPlayerHitCollider确保范围判定通过
        if(!g_hIntersects) hookOneFunc(g_fIntersects, hIntersects, (void**)&g_oIntersects, &g_hIntersects, "Intersects");
        if(!g_hCheckHit) hookOneFunc(g_fCheckHit, hCheckHit, (void**)&g_oCheckHit, &g_hCheckHit, "CheckHit");
        jlog(@"attackRangePlus: ON - HitSystem+Intersects+CheckHit hooked");
    } else {
        jlog(@"attackRangePlus: OFF");
    }
    refreshBtns();
}

// v117: ShowVideo hook — 跳过广告播放
// AdsHelper.ShowVideo(int adId, string adUnitId, bool multiton, bool isShow, bool isCardJump)
// C#实例方法, MSHookFunction可能传mi → hook 6参数(含mi), 原函数5参数
// 但也可能不传mi → 需要运行时检测
static int g_showVideoDebugLC=0;
static void hShowVideo(void *mi, void *self, int32_t adId, void *adUnitId, BOOL multiton, BOOL isShow, BOOL isCardJump) {
    // v117: 详细调试 — 前10次打印参数
    if(g_showVideoDebugLC < 10) {
        g_showVideoDebugLC++;
        jlog(@"ShowVideo[%d]: mi=%p self=%p adId=%d adUnitId=%p multiton=%d isShow=%d isCardJump=%d",
             g_showVideoDebugLC, mi, self, adId, adUnitId, multiton, isShow, isCardJump);
    }
    
    if(g_noAds) {
        // 捕获AdsHelper单例实例
        if(self && !g_adsHelperInstance) {
            g_adsHelperInstance = self;
            jlog(@"noAds: captured AdsHelper instance=%p", self);
            // 修改AdsHelper字段: AdsEnable=false, InAdsPlaying=false
            // IL2CPP对象: 有0x10 header(klass+monitor), 字段offset从0x10开始
            // AdsHelper字段offset(dump值): AdsEnable=0x30, InAdsPlaying=0x31, AdsSendEnable=0x32
            // IL2CPP引用类型的字段offset不需要减0x10(dump值就是实际偏移)
            uint8_t *p = (uint8_t*)self;
            p[0x30] = 0; // AdsEnable = false
            p[0x31] = 0; // InAdsPlaying = false
            jlog(@"noAds: set AdsEnable=0 InAdsPlaying=0 at instance %p", self);
        }
        jlog(@"noAds: BLOCKED ShowVideo adId=%d", adId);
        return; // 不播放广告, 直接返回
    }
    if(g_oShowVideo) ((ShowVideoFunc)g_oShowVideo)(self, adId, adUnitId, multiton, isShow, isCardJump);
}

// v117: IsAdAvailable hook — 返回false隐藏广告按钮
// 签名不确定: 可能4参数(含mi)或3参数(不含mi)
// 先用4参数, 如果参数异常(log中self=0或id=0)则改为3参数
static int g_isAdAvailDebugLC=0;
static BOOL hIsAdAvailable(void *mi, void *self, int32_t id, BOOL showButton) {
    // v117: 详细调试 — 前10次打印参数
    if(g_isAdAvailDebugLC < 10) {
        g_isAdAvailDebugLC++;
        jlog(@"IsAdAvailable[%d]: mi=%p self=%p id=%d showButton=%d",
             g_isAdAvailDebugLC, mi, self, id, showButton);
    }
    
    if(g_noAds) {
        // 也尝试捕获AdsHelper实例
        if(self && !g_adsHelperInstance) {
            g_adsHelperInstance = self;
            uint8_t *p = (uint8_t*)self;
            p[0x30] = 0; // AdsEnable = false
            p[0x31] = 0; // InAdsPlaying = false
            jlog(@"noAds: IsAdAvailable captured instance=%p, set fields", self);
        }
        return NO;
    }
    if(g_oIsAdAvailable) return ((IsAdAvailableFunc)g_oIsAdAvailable)(self, id, showButton);
    return NO;
}
@end

@interface JYJHResizeHandle : UIView { CGPoint _ts; }
@end
@implementation JYJHResizeHandle
-(instancetype)init{
    self=[super initWithFrame:CGRectMake(0,0,36,36)];
    if(self){
    self.backgroundColor=[UIColor clearColor];self.layer.zPosition=9999;
    UIView *t=[[UIView alloc]initWithFrame:CGRectMake(0,0,36,36)];t.backgroundColor=[UIColor colorWithRed:0.3 green:0.3 blue:0.4 alpha:0.85];t.layer.cornerRadius=6;[self addSubview:t];
    UILabel *l=[[UILabel alloc]initWithFrame:CGRectMake(0,0,36,36)];l.text=@"⇘";l.textColor=[UIColor whiteColor];l.font=[UIFont systemFontOfSize:18];l.textAlignment=NSTextAlignmentCenter;[self addSubview:l];
    }return self;
}
-(BOOL)pointInside:(CGPoint)p withEvent:(UIEvent*)e{return CGRectContainsPoint(CGRectInset(self.bounds,-6,-6),p);}
-(void)touchesBegan:(NSSet*)t withEvent:(UIEvent*)e{_ts=[[t anyObject]locationInView:g_panel.superview];}
-(void)touchesMoved:(NSSet*)t withEvent:(UIEvent*)e{
    CGPoint c=[[t anyObject]locationInView:g_panel.superview];
    CGFloat nw=MAX(200,c.x-g_panel.frame.origin.x);CGFloat nh=MAX(300,c.y-g_panel.frame.origin.y);
    g_panelW=nw;g_panelH=nh;g_panel.frame=CGRectMake(g_panel.frame.origin.x,g_panel.frame.origin.y,nw,nh);
    if(g_scrollView){g_scrollView.frame=CGRectMake(0,32,nw,nh-32);g_scrollView.contentSize=CGSizeMake(nw,g_scrollView.contentSize.height);}
    if(g_resizeHandle) g_resizeHandle.frame=CGRectMake(g_panel.frame.origin.x+nw-36,g_panel.frame.origin.y+nh-36,36,36);
    if(g_resizeHandleTop) g_resizeHandleTop.frame=CGRectMake(g_panel.frame.origin.x+nw-36,g_panel.frame.origin.y,36,36);
}
@end

@interface JYJHTitleDragView : UIView { CGPoint _ts; }
@end
@implementation JYJHTitleDragView
-(void)touchesBegan:(NSSet*)t withEvent:(UIEvent*)e{_ts=[[t anyObject]locationInView:g_panel.superview];}
-(void)touchesMoved:(NSSet*)t withEvent:(UIEvent*)e{
    CGPoint c=[[t anyObject]locationInView:g_panel.superview];CGFloat dx=c.x-_ts.x,dy=c.y-_ts.y;
    CGRect f=g_panel.frame;CGRect sc=[UIScreen mainScreen].bounds;
    f.origin.x=MAX(-f.size.width+40,MIN(sc.size.width-40,f.origin.x+dx));f.origin.y=MAX(-20,MIN(sc.size.height-60,f.origin.y+dy));
    g_panel.frame=f;
    if(g_resizeHandle) g_resizeHandle.frame=CGRectMake(f.origin.x+g_panelW-36,f.origin.y+g_panelH-36,36,36);
    if(g_resizeHandleTop) g_resizeHandleTop.frame=CGRectMake(f.origin.x+g_panelW-36,f.origin.y,36,36);
    _ts=c;
}
@end

@interface JYJHBallView : UIView { CGPoint _ts; BOOL _drag; }
@end
@implementation JYJHBallView
-(instancetype)init{
    self=[super initWithFrame:CGRectMake([UIScreen mainScreen].bounds.size.width-46,150,40,40)];
    if(self){
    self.backgroundColor=IMGUI_BALL_BG;self.layer.cornerRadius=20;self.layer.borderWidth=2;self.layer.borderColor=IMGUI_ACCENT.CGColor;self.userInteractionEnabled=YES;
    UILabel*l=[[UILabel alloc]initWithFrame:CGRectMake(0,0,40,40)];l.text=@"剑";l.textColor=[UIColor whiteColor];l.font=[UIFont boldSystemFontOfSize:18];l.textAlignment=NSTextAlignmentCenter;[self addSubview:l];
    }return self;
}
-(BOOL)pointInside:(CGPoint)p withEvent:(UIEvent*)e{return CGRectContainsPoint(CGRectInset(self.bounds,-8,-8),p);}
-(void)touchesBegan:(NSSet*)t withEvent:(UIEvent*)e{_ts=[[t anyObject]locationInView:self.superview];_drag=NO;}
-(void)touchesMoved:(NSSet*)t withEvent:(UIEvent*)e{CGPoint c=[[t anyObject]locationInView:self.superview];CGFloat dx=c.x-_ts.x,dy=c.y-_ts.y;if(fabs(dx)>5||fabs(dy)>5){_drag=YES;CGRect f=self.frame;CGRect sc=[UIScreen mainScreen].bounds;f.origin.x=MAX(0,MIN(sc.size.width-f.size.width,f.origin.x+dx));f.origin.y=MAX(50,MIN(sc.size.height-f.size.height-50,f.origin.y+dy));self.frame=f;_ts=c;}}
-(void)touchesEnded:(NSSet*)t withEvent:(UIEvent*)e{if(!_drag)togglePanel();_drag=NO;}
-(void)touchesCancelled:(NSSet*)t withEvent:(UIEvent*)e{_drag=NO;}
@end

static UIWindow *getKeyWindow(void){for(UIWindow *w in [UIApplication sharedApplication].windows)if(!w.isHidden)return w;return nil;}

static void setupUI(void){
    UIWindow *win=getKeyWindow();
    if(!win){dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{setupUI();});return;}
    JYJHBallView *ball=[[JYJHBallView alloc]init];[win addSubview:ball];
    UIView *outer=[[UIView alloc]initWithFrame:CGRectMake(0,0,g_panelW,g_panelH)];outer.backgroundColor=IMGUI_BG;outer.layer.cornerRadius=10;outer.layer.borderWidth=1;outer.layer.borderColor=IMGUI_BORDER.CGColor;outer.hidden=YES;g_panel=outer;[win addSubview:outer];
    layoutPanelCenter();
    JYJHTitleDragView *tb=[[JYJHTitleDragView alloc]initWithFrame:CGRectMake(0,0,g_panelW,32)];tb.backgroundColor=IMGUI_TITLE_BG;[outer addSubview:tb];g_titleBar=tb;
    UILabel *tl=[[UILabel alloc]initWithFrame:CGRectMake(10,6,g_panelW-20,20)];tl.text=@"剑影江湖 v116";tl.textColor=IMGUI_ACCENT;tl.font=[UIFont boldSystemFontOfSize:15];tl.textAlignment=NSTextAlignmentCenter;[tb addSubview:tl];
    UIScrollView *sv=[[UIScrollView alloc]initWithFrame:CGRectMake(0,32,g_panelW,g_panelH-32)];
    sv.showsVerticalScrollIndicator=YES;sv.delaysContentTouches=NO;sv.canCancelContentTouches=YES;sv.scrollEnabled=YES;sv.userInteractionEnabled=YES;
    [outer addSubview:sv]; g_scrollView=sv;
    CGFloat bx=12,bw=g_panelW-24,bh=24,by0=4,bdy=28;

    // 内容高度计算: 基础按钮8行 + 5技能按钮 + 伤害区(52+52) + 皮肤区(76*3+24) + 移动速度(28+28) + padding
    CGFloat contentH=by0+bdy*10+8+52+52+8+18+20+28+20+28+20+28+24+24+24+8+18+20+28+60+28;
    sv.contentSize=CGSizeMake(g_panelW,contentH);

    g_btnIgnoreUnlock=mkBtn(CGRectMake(bx,by0,bw,bh),@selector(onIgnoreUnlock));[sv addSubview:g_btnIgnoreUnlock];
    g_btnExSkillNoCD=mkBtn(CGRectMake(bx,by0+bdy,bw,bh),@selector(onExSkillNoCD));[sv addSubview:g_btnExSkillNoCD];
    g_btnGodMode=mkBtn(CGRectMake(bx,by0+bdy*2,bw,bh),@selector(onGodMode));[sv addSubview:g_btnGodMode];
    g_btnVacuum=mkBtn(CGRectMake(bx,by0+bdy*3,bw,bh),@selector(onVacuum));[sv addSubview:g_btnVacuum]; // v114: 吸怪
    g_btnAntiReport=mkBtn(CGRectMake(bx,by0+bdy*4,bw,bh),@selector(onAntiReport));[sv addSubview:g_btnAntiReport]; // v114: 反上报
    g_btnNoAds=mkBtn(CGRectMake(bx,by0+bdy*5,bw,bh),@selector(onNoAds));[sv addSubview:g_btnNoAds]; // v117: 免广告
    g_btnMonsterFreeze=mkBtn(CGRectMake(bx,by0+bdy*6,bw,bh),@selector(onMonsterFreeze));[sv addSubview:g_btnMonsterFreeze]; // v118: 怪不动
    g_btnAttackRangePlus=mkBtn(CGRectMake(bx,by0+bdy*7,bw,bh),@selector(onAttackRangePlus));[sv addSubview:g_btnAttackRangePlus]; // v118: 攻击范围+
    g_btnFullScreen=mkBtn(CGRectMake(bx,by0+bdy*8,bw,bh),@selector(onFullScreen));[sv addSubview:g_btnFullScreen];
    g_btnSkillReplace=mkBtn(CGRectMake(bx,by0+bdy*9,bw,bh),@selector(onSkillReplace));[sv addSubview:g_btnSkillReplace];
    CGFloat repY=by0+bdy*10;
    CGFloat sbw=(bw-4*5)/5;
    g_btnRepS1=mkBtn(CGRectMake(bx,repY,sbw,bh),@selector(onReplaceS1));[sv addSubview:g_btnRepS1];
    g_btnRepS2=mkBtn(CGRectMake(bx+sbw+4,repY,sbw,bh),@selector(onReplaceS2));[sv addSubview:g_btnRepS2];
    g_btnRepS3=mkBtn(CGRectMake(bx+(sbw+4)*2,repY,sbw,bh),@selector(onReplaceS3));[sv addSubview:g_btnRepS3];
    g_btnRepS4=mkBtn(CGRectMake(bx+(sbw+4)*3,repY,sbw,bh),@selector(onReplaceS4));[sv addSubview:g_btnRepS4];
    g_btnRepS5=mkBtn(CGRectMake(bx+(sbw+4)*4,repY,sbw,bh),@selector(onReplaceS5));[sv addSubview:g_btnRepS5];

    // === 伤害区域 ===
    CGFloat s1Y=by0+bdy*10+4;UIView *s1=[[UIView alloc]initWithFrame:CGRectMake(bx,s1Y,bw,1)];s1.backgroundColor=IMGUI_BORDER;[sv addSubview:s1];
    CGFloat sy=s1Y+8;
    g_sliderLabel=[[UILabel alloc]initWithFrame:CGRectMake(bx,sy,bw,18)];g_sliderLabel.text=[NSString stringWithFormat:@"伤害上限: %d",g_damageLimit];g_sliderLabel.textColor=IMGUI_DIMTEXT;g_sliderLabel.font=[UIFont systemFontOfSize:12];[sv addSubview:g_sliderLabel];
    g_slider=[[UISlider alloc]initWithFrame:CGRectMake(bx,sy+20,bw,28)];g_slider.minimumValue=1;g_slider.maximumValue=100000;g_slider.value=g_damageLimit;[g_slider addTarget:[JYJHActionHandler shared] action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];[sv addSubview:g_slider];

    CGFloat dmy=sy+52;
    g_dmgMultiLabel=[[UILabel alloc]initWithFrame:CGRectMake(bx,dmy,bw,18)];g_dmgMultiLabel.text=[NSString stringWithFormat:@"伤害倍数: ×%d",g_damageMulti];g_dmgMultiLabel.textColor=IMGUI_DIMTEXT;g_dmgMultiLabel.font=[UIFont systemFontOfSize:12];[sv addSubview:g_dmgMultiLabel];
    g_dmgMultiSlider=[[UISlider alloc]initWithFrame:CGRectMake(bx,dmy+20,bw,28)];g_dmgMultiSlider.minimumValue=1;g_dmgMultiSlider.maximumValue=10;g_dmgMultiSlider.value=g_damageMulti;[g_dmgMultiSlider addTarget:[JYJHActionHandler shared] action:@selector(dmgMultiChanged:) forControlEvents:UIControlEventValueChanged];[sv addSubview:g_dmgMultiSlider];

    // === 皮肤/武器/光环区域 ===
    CGFloat s2Y=dmy+52;UIView *s2=[[UIView alloc]initWithFrame:CGRectMake(bx,s2Y,bw,1)];s2.backgroundColor=IMGUI_BORDER;[sv addSubview:s2];
    CGFloat ssy=s2Y+6;
    int skinMax=g_skinIdsLoaded?g_roleSkinCount-1:2000;
    int weaponMax=g_skinIdsLoaded?g_weaponSkinCount-1:2000;
    int haloMax=g_skinIdsLoaded?g_haloSkinCount-1:2000;
    UILabel *secT=[[UILabel alloc]initWithFrame:CGRectMake(bx,ssy,bw,18)];
    secT.text=g_skinIdsLoaded?[NSString stringWithFormat:@"外观 (皮肤%d/武器%d/光环%d)",g_roleSkinCount,g_weaponSkinCount,g_haloSkinCount]:@"外观 (先点扫描)";
    secT.textColor=IMGUI_ACCENT;secT.font=[UIFont boldSystemFontOfSize:11];[sv addSubview:secT];

    CGFloat cy=ssy+20;
    g_skinLabel=[[UILabel alloc]initWithFrame:CGRectMake(bx,cy,bw,18)];g_skinLabel.text=[NSString stringWithFormat:@"皮肤ID: %d",g_skinId];g_skinLabel.textColor=IMGUI_DIMTEXT;g_skinLabel.font=[UIFont systemFontOfSize:12];[sv addSubview:g_skinLabel];
    g_skinSlider=[[UISlider alloc]initWithFrame:CGRectMake(bx,cy+18,bw,28)];g_skinSlider.minimumValue=0;g_skinSlider.maximumValue=skinMax;g_skinSlider.value=0;[g_skinSlider addTarget:[JYJHActionHandler shared] action:@selector(skinSliderChanged:) forControlEvents:UIControlEventValueChanged];[sv addSubview:g_skinSlider];
    g_btnApplySkin=mkBtn(CGRectMake(bx,cy+48,bw,bh),@selector(onApplySkin));[sv addSubview:g_btnApplySkin];

    cy+=76;
    g_weaponLabel=[[UILabel alloc]initWithFrame:CGRectMake(bx,cy,bw,18)];g_weaponLabel.text=[NSString stringWithFormat:@"武器ID: %d",g_weaponId];g_weaponLabel.textColor=IMGUI_DIMTEXT;g_weaponLabel.font=[UIFont systemFontOfSize:12];[sv addSubview:g_weaponLabel];
    g_weaponSlider=[[UISlider alloc]initWithFrame:CGRectMake(bx,cy+18,bw,28)];g_weaponSlider.minimumValue=0;g_weaponSlider.maximumValue=weaponMax;g_weaponSlider.value=0;[g_weaponSlider addTarget:[JYJHActionHandler shared] action:@selector(weaponSliderChanged:) forControlEvents:UIControlEventValueChanged];[sv addSubview:g_weaponSlider];
    g_btnApplyWeapon=mkBtn(CGRectMake(bx,cy+48,bw,bh),@selector(onApplyWeapon));[sv addSubview:g_btnApplyWeapon];

    cy+=76;
    g_haloLabel=[[UILabel alloc]initWithFrame:CGRectMake(bx,cy,bw,18)];g_haloLabel.text=[NSString stringWithFormat:@"光环ID: %d",g_haloId];g_haloLabel.textColor=IMGUI_DIMTEXT;g_haloLabel.font=[UIFont systemFontOfSize:12];[sv addSubview:g_haloLabel];
    g_haloSlider=[[UISlider alloc]initWithFrame:CGRectMake(bx,cy+18,bw,28)];g_haloSlider.minimumValue=0;g_haloSlider.maximumValue=haloMax;g_haloSlider.value=0;[g_haloSlider addTarget:[JYJHActionHandler shared] action:@selector(haloSliderChanged:) forControlEvents:UIControlEventValueChanged];[sv addSubview:g_haloSlider];
    g_btnApplyHalo=mkBtn(CGRectMake(bx,cy+48,bw,bh),@selector(onApplyHalo));[sv addSubview:g_btnApplyHalo];

    cy+=76;
    g_btnScanSkin=mkBtn(CGRectMake(bx,cy,bw,bh),@selector(onDumpSkinIds));[sv addSubview:g_btnScanSkin];

    // === 移动速度 ===
    cy+=28;UIView *s3=[[UIView alloc]initWithFrame:CGRectMake(bx,cy,bw,1)];s3.backgroundColor=IMGUI_BORDER;[sv addSubview:s3];
    CGFloat spy=cy+4;
    g_speedLabel=[[UILabel alloc]initWithFrame:CGRectMake(bx,spy,bw,18)];g_speedLabel.text=[NSString stringWithFormat:@"移动速度: %.1fx",g_speedMul];g_speedLabel.textColor=IMGUI_ACCENT;g_speedLabel.font=[UIFont boldSystemFontOfSize:12];[sv addSubview:g_speedLabel];
    g_speedSlider=[[UISlider alloc]initWithFrame:CGRectMake(bx,spy+20,bw,28)];g_speedSlider.minimumValue=1.0;g_speedSlider.maximumValue=5.0;g_speedSlider.value=g_speedMul;[g_speedSlider addTarget:[JYJHActionHandler shared] action:@selector(speedSliderChanged:) forControlEvents:UIControlEventValueChanged];[sv addSubview:g_speedSlider];

    g_resizeHandle=[[JYJHResizeHandle alloc]init];
    CGRect panelFrame=g_panel.frame;
    g_resizeHandle.frame=CGRectMake(panelFrame.origin.x+g_panelW-36,panelFrame.origin.y+g_panelH-36,36,36);g_resizeHandle.hidden=YES;[win addSubview:g_resizeHandle];
    g_resizeHandleTop=[[JYJHResizeHandle alloc]init];
    g_resizeHandleTop.frame=CGRectMake(panelFrame.origin.x+g_panelW-36,panelFrame.origin.y,36,36);g_resizeHandleTop.hidden=YES;[win addSubview:g_resizeHandleTop];
    refreshBtns();
}

__attribute__((constructor))
static void initialize(void){
    static BOOL loaded=NO; if(loaded)return; loaded=YES;
    jlog(@"========== JYJH v116 (vacuum fix + noAds) ==========");
    jlog(@"iOS %@",[[UIDevice currentDevice] systemVersion]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(5.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        jlog(@"5s delay done"); applyAllHooks();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{setupUI();});
    });
}
