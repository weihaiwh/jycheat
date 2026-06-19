/**
 * v61.0 - 修复三个问题 + 增加诊断
 * v60测试:
 *   1. 标题仍显示v59 (硬编码未更新)
 *   2. 皮肤扫描0: ConfigComponent.Awake Hook成功, 但扫描时实例未保存
 *      → 改为通过GameEntry._config静态字段(0xa8)获取ConfigComponent实例
 *   3. 大招增强无效果: IsExSkillInCD Hook成功但从未被触发(无forced NO日志)
 *      → TryTriggerExSkill也没效果→帧同步ExSkill由服务端控制?
 *      → v61: 换Hook TryTriggerExSkill, 修改为总是触发; 同时保留IsExSkillInCD
 *   4. HitSystem: dump显示self+0x38开始全0(战斗中), collBound偏移可能需要更多扫描
 *      → v61: 扩大dump范围到self+0x80, 并dump更多HitSystem实例
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
static void jlog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void jlog(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[JYJH] %@", msg);
    if (!g_logFile) { NSString *p = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/jyjh.log"]; g_logFile = fopen([p UTF8String], "a"); }
    if (g_logFile) { fprintf(g_logFile, "%s\n", [msg UTF8String]); fflush(g_logFile); }
}

static BOOL g_ignoreUnlock=NO, g_exSkillNoCD=NO, g_godMode=NO, g_fullScreen=NO, g_exSkillAlways=NO;
static int g_damageLimit=100, g_skinId=0, g_weaponId=0;

typedef BOOL (*BoolFunc3)(void*,int,int);
typedef int (*IntFunc1)(void*);
typedef BOOL (*BoolFunc4)(void*,int,void*,void*);
typedef BOOL (*CanBeAttackFunc)(void*);
typedef int64_t (*DamageFunc)(void*,void*,void*,void*,void*,int32_t,int32_t,BOOL,int32_t,int32_t,void*,void*);
typedef int64_t (*DecreaseHPFunc)(void*,void*,void*,void*,int64_t);
typedef BOOL (*IntersectsFunc)(void*,void*);
typedef int32_t (*CheckHitFunc)(void*,void*);
typedef void (*MonsterDeadSignalFunc)(void*,void*,void*,void*,int32_t);

static void *g_fUnlock=NULL; static BoolFunc3 g_oUnlock=NULL; static BOOL g_hUnlock=NO;
static void *g_fLimitDmg=NULL; static IntFunc1 g_oLimitDmg=NULL; static BOOL g_hLimitDmg=NO;
static void *g_fIsReady=NULL; static BoolFunc4 g_oIsReady=NULL; static BOOL g_hIsReady=NO;
static void *g_fAttackCanUse=NULL; static BoolFunc4 g_oAttackCanUse=NULL; static BOOL g_hAttackCanUse=NO;
static void *g_fCanBeAttack=NULL; static CanBeAttackFunc g_oCanBeAttack=NULL; static BOOL g_hCanBeAttack=NO;
static void *g_fDamage=NULL; static DamageFunc g_oDamage=NULL; static BOOL g_hDamage=NO;
static void *g_fIntersects=NULL; static IntersectsFunc g_oIntersects=NULL; static BOOL g_hIntersects=NO;
static void *g_fCheckHit=NULL; static CheckHitFunc g_oCheckHit=NULL; static BOOL g_hCheckHit=NO;
static void *g_fMonsterDead=NULL;

// v53: HitSystem.Update Hook
typedef void (*HitSystemUpdateFunc)(void*,void*);
static void *g_fHitSystemUpdate=NULL; static HitSystemUpdateFunc g_oHitSystemUpdate=NULL; static BOOL g_hHitSystemUpdate=NO;

static DecreaseHPFunc g_origDecreaseHP = NULL;
static void *g_classActor=NULL;

// v54: 皮肤修改
static void *g_playerActorObj=NULL;
static int32_t g_appliedSkinId=0, g_appliedWeaponId=0;
typedef void (*UpdatePartFunc)(void*,int32_t,int32_t,int32_t);
static void *g_fUpdatePart=NULL;

// v55: Hook Actor.get_SkinId
typedef int32_t (*GetSkinIdFunc)(void*);
static void *g_fGetSkinId=NULL; static GetSkinIdFunc g_oGetSkinId=NULL; static BOOL g_hGetSkinId=NO;
static int g_skinIdHookLC=0;
static int32_t hGetSkinId(void *self) {
    if(self && !g_playerActorObj) {
        g_playerActorObj=self;
        int32_t skinId=0,weaponId=0;
        memcpy(&skinId,(uint8_t*)self+0x110,4);
        memcpy(&weaponId,(uint8_t*)self+0x114,4);
        jlog(@"FOUND player Actor=%p skin=%d weapon=%d",self,skinId,weaponId);
    }
    if(g_skinIdHookLC<5){g_skinIdHookLC++;jlog(@"get_SkinId: self=%p isPlayer=%d",self,self==g_playerActorObj);}
    int32_t r=g_oGetSkinId?g_oGetSkinId(self):0;
    if(self==g_playerActorObj && g_appliedSkinId>0) return g_appliedSkinId;
    return r;
}

// v61: HitSystem - 保留偏移但扩大dump范围以诊断
#define HITSYS_COLLBOUND_OFF 0x38
#define HITSYS_EXTENTS_X_OFF (HITSYS_COLLBOUND_OFF+0x10)  // 0x48
#define HITSYS_EXTENTS_Y_OFF (HITSYS_COLLBOUND_OFF+0x18)  // 0x50
static int64_t g_savedExtX=0, g_savedExtY=0;

// v61: 大招增强 - Hook TryTriggerExSkill(8参) 让其总触发
// 之前Hook IsExSkillInCD无效果(从未调用), 可能ExSkill在帧同步中走不同路径
// TryTriggerExSkill: static bool(Frame, ExSkillTriggerType, EntityRef, EntityRef, List<EntityRef>, CharacterFiled*, ExSkillsAsset, UInt64)
typedef int8_t (*TryTriggerExSkillFunc)(void*,uint64_t,void*,void*,void*,void*,void*,uint64_t);
static void *g_fTryTriggerExSkill=NULL; static TryTriggerExSkillFunc g_oTryTriggerExSkill=NULL; static BOOL g_hTryTriggerExSkill=NO;
static int g_tryExSkillLC=0;
static int8_t hTryTriggerExSkill(void *f,uint64_t triggerType,void *trigger,void *fuse,void *targets,void *cf,void *asset,uint64_t triggerData) {
    int8_t r=g_oTryTriggerExSkill?g_oTryTriggerExSkill(f,triggerType,trigger,fuse,targets,cf,asset,triggerData):0;
    if(g_exSkillAlways && g_tryExSkillLC<30) {
        g_tryExSkillLC++;
        jlog(@"TryTriggerExSkill[%d]: type=%llu ret=%d",g_tryExSkillLC,(unsigned long long)triggerType,r);
    }
    return r;
}

// v61: 保留IsExSkillInCD Hook作为备用诊断
typedef BOOL (*IsExSkillInCDFunc)(int64_t,void*,void*);
static void *g_fIsExSkillInCD=NULL; static IsExSkillInCDFunc g_oIsExSkillInCD=NULL; static BOOL g_hIsExSkillInCD=NO;
static int g_exSkillInCDLC=0;
static BOOL hIsExSkillInCD(int64_t now,void *skillp,void *info) {
    BOOL orig=g_oIsExSkillInCD?g_oIsExSkillInCD(now,skillp,info):NO;
    if(g_exSkillInCDLC<30){g_exSkillInCDLC++;jlog(@"IsExSkillInCD[%d]: orig=%d forced=%d",g_exSkillInCDLC,orig,g_exSkillAlways?0:orig);}
    if(g_exSkillAlways) return NO;
    return orig;
}

static void *g_playerCF=NULL, *g_playerEntity=NULL; static BOOL g_playerCFLearned=NO;
#define MAX_ENEMIES 64
static void *g_enemyCFs[MAX_ENEMIES], *g_enemyEntities[MAX_ENEMIES]; static int g_enemyCount=0;

// v61: 皮肤扫描 - 通过GameEntry._config静态字段获取ConfigComponent实例
// GameEntry类有静态字段 _config at class static data offset 0xa8
// ConfigComponent.<Tables>k__BackingField at +0x28
// cfg.Tables → TbRoleSkin at +0x230
#define MAX_SKIN_IDS 256
static int32_t g_roleSkinIds[MAX_SKIN_IDS], g_weaponSkinIds[MAX_SKIN_IDS];
static int g_roleSkinCount=0, g_weaponSkinCount=0;
static BOOL g_skinIdsLoaded=NO;
static void *g_classConfigComponent=NULL;
static void *g_classGameEntry=NULL;
static void *g_configCompInstance=NULL;

static BOOL isValidPtr(void *p) {
    if(!p) return NO;
    uint64_t v=0; memcpy(&v,&p,8);
    return (v>=0x100000000ULL && v<=0x1FFFFFFFFFFFULL);
}

// v61: 获取ConfigComponent实例 - 通过GameEntry._config静态字段
// GameEntry是静态类, _config字段在类静态数据区offset 0xa8
static void *getConfigCompInstance(void) {
    // 方案1: 如果已有Awake Hook保存的实例
    if(isValidPtr(g_configCompInstance)) return g_configCompInstance;

    // 方案2: 通过GameEntry._config静态字段
    // il2cpp中类的静态字段存在class->static_fields指向的内存中
    // 使用il2cpp_class_get_static_field_data或直接读class的static_fields
    if(!g_classGameEntry) return NULL;

    // Il2CppClass结构中, static_fields指针在固定偏移
    // 不同IL2CPP版本偏移不同, 我们用il2cpp_class_get_static_field_data
    void *h=dlopen(NULL,RTLD_LAZY);
    if(!h) return NULL;
    typedef void* (*Il2CppClassGetStaticFieldData)(void*);
    Il2CppClassGetStaticFieldData get_sfd=dlsym(h,"il2cpp_class_get_static_field_data");
    if(get_sfd) {
        void *staticData=get_sfd(g_classGameEntry);
        if(staticData) {
            // GameEntry._config at offset 0xa8 in static data
            void *configComp=NULL;
            memcpy(&configComp,(uint8_t*)staticData+0xa8,8);
            jlog(@"GameEntry._config from staticData=%p → configComp=%p",staticData,configComp);
            if(isValidPtr(configComp)) {
                g_configCompInstance=configComp;
                return configComp;
            }
            // dump static data前0xb0字节
            jlog(@"GameEntry static data dump (first 0xb0 bytes):");
            for(int i=0;i<22;i++){
                uint64_t v=0; memcpy(&v,(uint8_t*)staticData+i*8,8);
                jlog(@"  SD[+0x%x]=0x%llx",i*8,v);
            }
        } else {
            jlog(@"GameEntry staticData is NULL");
        }
    } else {
        jlog(@"il2cpp_class_get_static_field_data not found");
    }
    return NULL;
}

static void scanSkinIds(void) {
    if(g_skinIdsLoaded) return;
    g_skinIdsLoaded=YES;
    g_roleSkinCount=0; g_weaponSkinCount=0;

    // v61: 尝试获取ConfigComponent实例
    void *cc=getConfigCompInstance();
    if(!isValidPtr(cc)){
        jlog(@"ScanSkin: ConfigComponent instance not found (tried GameEntry._config)");
        // 兜底: 直接搜索il2cpp_class_get_static_field_data
        void *h=dlopen(NULL,RTLD_LAZY);
        if(h && g_classConfigComponent) {
            typedef void* (*Il2CppClassGetStaticFieldData)(void*);
            Il2CppClassGetStaticFieldData get_sfd=dlsym(h,"il2cpp_class_get_static_field_data");
            if(get_sfd) {
                // ConfigComponent可能也有静态字段但不太可能, 跳过
                jlog(@"ScanSkin: ConfigComponent class=%p, no instance available",g_classConfigComponent);
            }
        }
        g_skinIdsLoaded=NO; // 允许重试
        return;
    }

    jlog(@"ScanSkin: using configComp=%p",cc);

    // ConfigComponent.<Tables>k__BackingField at +0x28 (class field, dump=actual)
    void *tables_l=NULL;
    memcpy(&tables_l,(uint8_t*)cc+0x28,8);
    jlog(@"ScanSkin: tables=%p",tables_l);
    if(!isValidPtr(tables_l)){
        // dump ConfigComponent对象前0x60字节
        jlog(@"ScanSkin: tables invalid, dumping ConfigComponent:");
        for(int i=0;i<12;i++){
            uint64_t v=0; memcpy(&v,(uint8_t*)cc+i*8,8);
            jlog(@"  CC[+0x%x]=0x%llx",i*8,v);
        }
        g_skinIdsLoaded=NO;
        return;
    }

    // Tables.TbRoleSkin at +0x230 (class field, dump=actual)
    void *tbRoleSkin=NULL;
    memcpy(&tbRoleSkin,(uint8_t*)tables_l+0x230,8);
    jlog(@"ScanSkin: tbRoleSkin=%p",tbRoleSkin);
    if(!isValidPtr(tbRoleSkin)){
        jlog(@"ScanSkin: TbRoleSkin invalid, dumping Tables valid ptrs:");
        for(int i=0;i<80;i++){
            uint64_t v=0; memcpy(&v,(uint8_t*)tables_l+i*8,8);
            if(isValidPtr((void*)v)){
                jlog(@"  Tables[0x%x]=%p",i*8,(void*)v);
            }
        }
        g_skinIdsLoaded=NO;
        return;
    }

    // TbRoleSkin._dataList at +0x18 (class field, dump=actual)
    void *dataList=NULL;
    memcpy(&dataList,(uint8_t*)tbRoleSkin+0x18,8);
    jlog(@"ScanSkin: dataList=%p",dataList);
    if(!isValidPtr(dataList)){jlog(@"ScanSkin: _dataList ptr invalid");g_skinIdsLoaded=NO;return;}

    // List<RoleSkin>._items at +0x10, _size at +0x18
    void *itemsArray=NULL; int32_t listSize=0;
    memcpy(&itemsArray,(uint8_t*)dataList+0x10,8);
    memcpy(&listSize,(uint8_t*)dataList+0x18,4);
    jlog(@"ScanSkin: itemsArray=%p listSize=%d",itemsArray,listSize);
    if(!itemsArray||listSize<=0||!isValidPtr(itemsArray)){jlog(@"ScanSkin: List empty or invalid");g_skinIdsLoaded=NO;return;}

    int32_t arrayLen=0;
    memcpy(&arrayLen,(uint8_t*)itemsArray+0x10,4);
    jlog(@"ScanSkin: arrayLen=%d",arrayLen);

    int maxScan=(listSize<MAX_SKIN_IDS)?listSize:MAX_SKIN_IDS;
    for(int i=0;i<maxScan&&i<arrayLen;i++){
        void *roleSkinPtr=NULL;
        memcpy(&roleSkinPtr,(uint8_t*)itemsArray+0x20+i*8,8);
        if(!roleSkinPtr)continue;
        int32_t skinId=0;
        memcpy(&skinId,(uint8_t*)roleSkinPtr+0x10,4);
        if(skinId>0) g_roleSkinIds[g_roleSkinCount++]=skinId;
    }
    jlog(@"ScanSkinIds: found %d role skin IDs",g_roleSkinCount);
    for(int i=0;i<g_roleSkinCount&&i<20;i++) jlog(@"  RoleSkin[%d]=%d",i,g_roleSkinIds[i]);

    // 同样读取TbWeaponSkin
    void *tbWeaponSkin=NULL;
    memcpy(&tbWeaponSkin,(uint8_t*)tables_l+0x248,8);
    if(isValidPtr(tbWeaponSkin)){
        void *wDataList=NULL;
        memcpy(&wDataList,(uint8_t*)tbWeaponSkin+0x18,8);
        if(isValidPtr(wDataList)){
            void *wItemsArray=NULL; int32_t wListSize=0;
            memcpy(&wItemsArray,(uint8_t*)wDataList+0x10,8);
            memcpy(&wListSize,(uint8_t*)wDataList+0x18,4);
            if(wItemsArray&&wListSize>0){
                int wMax=(wListSize<MAX_SKIN_IDS)?wListSize:MAX_SKIN_IDS;
                for(int i=0;i<wMax;i++){
                    void *wsPtr=NULL;
                    memcpy(&wsPtr,(uint8_t*)wItemsArray+0x20+i*8,8);
                    if(!wsPtr)continue;
                    int32_t wId=0;
                    memcpy(&wId,(uint8_t*)wsPtr+0x10,4);
                    if(wId>0) g_weaponSkinIds[g_weaponSkinCount++]=wId;
                }
            }
        }
    }
    jlog(@"ScanSkinIds: found %d weapon skin IDs",g_weaponSkinCount);
    for(int i=0;i<g_weaponSkinCount&&i<20;i++) jlog(@"  WeaponSkin[%d]=%d",i,g_weaponSkinIds[i]);
}

static BOOL isPlayerCF(void *cf) { if(!cf)return NO; int32_t v=-1; memcpy(&v,(uint8_t*)cf+0x44,4); return v==0; }
static BOOL isDeadCF(void *cf) { if(!cf)return YES; int32_t v=-1; memcpy(&v,(uint8_t*)cf+0x48,4); return v!=0; }
static void trackEnemy(void *cf, void *ent) {
    if(!cf||!ent||isPlayerCF(cf))return;
    for(int i=0;i<g_enemyCount;i++) if(g_enemyCFs[i]==cf){g_enemyEntities[i]=ent;return;}
    if(g_enemyCount<MAX_ENEMIES){g_enemyCFs[g_enemyCount]=cf;g_enemyEntities[g_enemyCount]=ent;g_enemyCount++;}
}

// ===== Hooks =====
static int g_unlockLC=0;
static BOOL hUnlock(void *s,int a1,int a2){if(g_ignoreUnlock){if(g_unlockLC<5){g_unlockLC++;}return YES;}return g_oUnlock?g_oUnlock(s,a1,a2):YES;}
static int g_isReadyLC=0;
static BOOL hIsReady(void *f,int st,void *cf,void *st2){
    if(cf){if(isPlayerCF(cf)){if(!g_playerCFLearned){g_playerCF=cf;g_playerCFLearned=YES;jlog(@"PlayerCF=%p",cf);}}else trackEnemy(cf,NULL);}
    if(g_exSkillNoCD&&st>=17){if(g_isReadyLC<30)g_isReadyLC++;return YES;}
    return g_oIsReady?g_oIsReady(f,st,cf,st2):YES;
}
static int g_attackLC=0;
static BOOL hAttackCanUse(void *f,int st,void *cf,void *st2){
    if(cf&&isPlayerCF(cf)&&!g_playerCFLearned){g_playerCF=cf;g_playerCFLearned=YES;}
    if(g_exSkillNoCD&&st>=17){if(g_attackLC<30)g_attackLC++;return YES;}
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
    if(g_godMode&&tgtP){if(g_dmgLC<20){g_dmgLC++;jlog(@"Dmg:Player->0");}return 0;}
    if(!g_oDamage)return 0;
    int64_t r=g_oDamage(f,atkEnt,atkCF,tgtEnt,tgtCF,hitEid,hitSnd,isR,sBtn,sPart,hurtF,exS);
    if(atkP&&r>0){if(g_dmgLC<20){g_dmgLC++;jlog(@"Dmg[%d]=%lld enemies=%d",g_dmgLC,r,g_enemyCount);}}
    return r;
}
static BOOL hIntersects(void *s,void *o){if(g_fullScreen)return YES;return g_oIntersects?g_oIntersects(s,o):NO;}
static int32_t hCheckHit(void *f,void *cb){if(g_fullScreen)return 1;return g_oCheckHit?g_oCheckHit(f,cb):0;}

// v61: HitSystem.Update Hook - 扩大dump范围诊断collBound
static int g_hitSysLC=0;
static void hHitSystemUpdate(void *self, void *framePtr) {
    if(!self) { if(g_oHitSystemUpdate) g_oHitSystemUpdate(self, framePtr); return; }

    // v61: 首次调用时dump更多内存(到+0x80)
    if(g_hitSysLC<5) {
        g_hitSysLC++;
        uint8_t *p=(uint8_t*)self;
        jlog(@"HitSys[%d] self=%p dump to +0x80:", g_hitSysLC, self);
        for(int i=0;i<16;i++){
            int64_t v=0; memcpy(&v,p+i*8,8);
            jlog(@"  [+0x%x]=%lld(0x%llx)",i*8,v,v);
        }
    }

    if(!g_fullScreen) {
        if(g_oHitSystemUpdate) g_oHitSystemUpdate(self, framePtr);
        return;
    }
    // 保存collBound Extents原始值
    uint8_t *p=(uint8_t*)self;
    memcpy(&g_savedExtX, p+HITSYS_EXTENTS_X_OFF, 8);
    memcpy(&g_savedExtY, p+HITSYS_EXTENTS_Y_OFF, 8);
    // v61: 只有在原始值非0时才修改(避免在未初始化时写入)
    if(g_savedExtX!=0 || g_savedExtY!=0) {
        // 设为超大值
        int64_t huge=0x7FFFFFFFFFFFFFFF;
        memcpy(p+HITSYS_EXTENTS_X_OFF, &huge, 8);
        memcpy(p+HITSYS_EXTENTS_Y_OFF, &huge, 8);
        // 调用原始Update
        if(g_oHitSystemUpdate) g_oHitSystemUpdate(self, framePtr);
        // 恢复
        memcpy(p+HITSYS_EXTENTS_X_OFF, &g_savedExtX, 8);
        memcpy(p+HITSYS_EXTENTS_Y_OFF, &g_savedExtY, 8);
    } else {
        // collBound未初始化, 直接调原始
        if(g_oHitSystemUpdate) g_oHitSystemUpdate(self, framePtr);
    }
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
    jlog(@"=== v61.0 IL2CPP Search ===");
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
    if(!domain_get||!method_name){jlog(@"IL2CPP APIs not found");return;}
    void *domain=domain_get(); if(!domain)return;
    size_t assemCount=0; void **assemblies=get_assemblies(domain,&assemCount);
    if(!assemblies)return;
    jlog(@"assemblies=%p count=%zu",assemblies,assemCount);
    int found=0,totalMethods=0;
    for(size_t a=0;a<assemCount;a++){
        void *img=get_image(assemblies[a]); if(!img)continue;
        size_t cnt=class_count?class_count(img):0;
        for(size_t c=0;c<cnt;c++){
            void *klass=get_class(img,c); if(!klass)continue;
            const char *cn=class_name_func?class_name_func(klass):NULL;
            if(cn&&strcmp(cn,"Actor")==0&&!g_classActor){
                g_classActor=klass; jlog(@"FOUND class Actor=%p",klass);
            }
            // v61: 搜索GameEntry类
            if(cn&&strcmp(cn,"GameEntry")==0&&!g_classGameEntry){
                g_classGameEntry=klass; jlog(@"FOUND class GameEntry=%p",klass);
            }
            if(cn&&strcmp(cn,"ConfigComponent")==0&&!g_classConfigComponent){
                g_classConfigComponent=klass; jlog(@"FOUND class ConfigComponent=%p",klass);
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
                else if(strcmp(n,"DecreaseHP")==0&&pc==5){if(!g_origDecreaseHP){g_origDecreaseHP=(DecreaseHPFunc)fa;jlog(@"FOUND DecreaseHP %p (saved)",fa);}}
                else if(strcmp(n,"Intersects")==0&&pc==1&&cn&&strstr(cn,"FPBounds2")!=NULL&&!g_fIntersects){g_fIntersects=fa;found++;jlog(@"FOUND %s.%s p=%u %p",cn?:"?",n,pc,fa);}
                else if(strcmp(n,"CheckPlayerHitCollider")==0&&pc==2&&!g_fCheckHit){g_fCheckHit=fa;found++;jlog(@"FOUND %s.%s p=%u %p",cn?:"?",n,pc,fa);}
                else if(strcmp(n,"MonsterDeadSignal")==0&&pc==4&&!g_fMonsterDead){g_fMonsterDead=fa;found++;jlog(@"FOUND %s.%s p=%u %p",cn?:"?",n,pc,fa);}
                else if(strcmp(n,"Update")==0&&pc==1&&cn&&strcmp(cn,"HitSystem")==0&&!g_fHitSystemUpdate){g_fHitSystemUpdate=fa;found++;jlog(@"FOUND %s.%s p=%u %p",cn?:"?",n,pc,fa);}
                else if(strcmp(n,"UpdatePart")==0&&pc==3&&!g_fUpdatePart){g_fUpdatePart=fa;found++;jlog(@"FOUND %s.%s p=%u %p",cn?:"?",n,pc,fa);}
                else if(strcmp(n,"get_SkinId")==0&&pc==0&&cn&&strcmp(cn,"Actor")==0&&!g_fGetSkinId){g_fGetSkinId=fa;found++;jlog(@"FOUND %s.%s p=%u %p",cn?:"?",n,pc,fa);}
                // v61: 搜索TryTriggerExSkill(8参) - 大招触发
                else if(strcmp(n,"TryTriggerExSkill")==0&&pc==8&&!g_fTryTriggerExSkill){
                    g_fTryTriggerExSkill=fa;found++;jlog(@"FOUND %s.%s p=%u %p [大招触发]",cn?:"?",n,pc,fa);
                }
                // v61: 保留IsExSkillInCD搜索(3参)
                else if(strcmp(n,"IsExSkillInCD")==0&&pc==3&&!g_fIsExSkillInCD){
                    g_fIsExSkillInCD=fa;found++;jlog(@"FOUND %s.%s p=%u %p [大招CD]",cn?:"?",n,pc,fa);
                }
            }
        }
    }
    jlog(@"Scanned %d methods, found %d targets, origDecreaseHP=%p",totalMethods,found,g_origDecreaseHP);
}

static void hookOneFunc(void *fa,void *hf,void **of,BOOL *hf2,const char *name){
    if(!fa){jlog(@"%s: not found",name);return;}
    if(*hf2){jlog(@"%s: already hooked",name);return;}
    int r=DobbyHook(fa,hf,of);
    if(r==0){*hf2=YES;jlog(@"%s: OK at %p orig=%p",name,fa,*of);}
    else jlog(@"%s: FAILED ret=%d",name,r);
}

static void applyAllHooks(void){if(!g_fLimitDmg)findIL2CPP();hookOneFunc(g_fLimitDmg,hLimitDmg,(void**)&g_oLimitDmg,&g_hLimitDmg,"limitDmg");jlog(@"applyAllHooks done");}

// ===== UI =====
static UIView *g_panel=nil, *g_titleBar=nil;
static UIScrollView *g_scrollView=nil;
static UIButton *g_btnIgnoreUnlock=nil,*g_btnExSkillNoCD=nil,*g_btnGodMode=nil,*g_btnFullScreen=nil,*g_btnApplySkin=nil,*g_btnScanSkin=nil,*g_btnExSkillAlways=nil;
static UISlider *g_slider=nil,*g_skinSlider=nil,*g_weaponSlider=nil;
static UILabel *g_sliderLabel=nil,*g_skinLabel=nil,*g_weaponLabel=nil;
static BOOL g_panelOpen=NO;
static CGFloat g_panelW=360, g_panelH=560;
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
-(void)onIgnoreUnlock;-(void)onExSkillNoCD;-(void)onGodMode;-(void)onFullScreen;-(void)onApplySkin;
-(void)sliderChanged:(UISlider*)s;-(void)skinSliderChanged:(UISlider*)s;-(void)weaponSliderChanged:(UISlider*)s;
-(void)onDumpSkinIds;-(void)onExSkillAlways;
@end

static UIButton* mkBtn(CGRect f,SEL a){
    UIButton *b=[UIButton buttonWithType:UIButtonTypeCustom];
    b.frame=f;b.layer.cornerRadius=4;b.layer.borderWidth=1;b.layer.borderColor=IMGUI_BORDER.CGColor;
    b.titleLabel.font=[UIFont boldSystemFontOfSize:13];b.titleLabel.textColor=IMGUI_TEXT;
    [b addTarget:[JYJHActionHandler shared] action:a forControlEvents:UIControlEventTouchUpInside];
    return b;
}

static void refreshBtns(void){
    if(g_ignoreUnlock){[g_btnIgnoreUnlock setTitle:@"ON  \xe5\xbf\xbd\xe7\x95\xa5\xe8\xa7\xa3\xe9\x94\x81" forState:UIControlStateNormal];g_btnIgnoreUnlock.backgroundColor=IMGUI_BTN_ON;g_btnIgnoreUnlock.layer.borderColor=IMGUI_GREEN.CGColor;}
    else{[g_btnIgnoreUnlock setTitle:@"OFF \xe5\xbf\xbd\xe7\x95\xa5\xe8\xa7\xa3\xe9\x94\x81" forState:UIControlStateNormal];g_btnIgnoreUnlock.backgroundColor=IMGUI_BTN_OFF;g_btnIgnoreUnlock.layer.borderColor=IMGUI_RED.CGColor;}
    if(g_exSkillNoCD){[g_btnExSkillNoCD setTitle:@"ON  \xe6\x8a\x80\xe8\x83\xbd\xe6\x97" "\xa0" "CD" forState:UIControlStateNormal];g_btnExSkillNoCD.backgroundColor=IMGUI_BTN_ON;g_btnExSkillNoCD.layer.borderColor=IMGUI_GREEN.CGColor;}
    else{[g_btnExSkillNoCD setTitle:@"OFF \xe6\x8a\x80\xe8\x83\xbd\xe6\x97" "\xa0" "CD" forState:UIControlStateNormal];g_btnExSkillNoCD.backgroundColor=IMGUI_BTN_OFF;g_btnExSkillNoCD.layer.borderColor=IMGUI_RED.CGColor;}
    if(g_godMode){[g_btnGodMode setTitle:@"ON  \xe7\x8e\xa9\xe5\xae\xb6\xe4\xb8\x8d\xe6\xad\xbb" forState:UIControlStateNormal];g_btnGodMode.backgroundColor=IMGUI_BTN_ON;g_btnGodMode.layer.borderColor=IMGUI_GREEN.CGColor;}
    else{[g_btnGodMode setTitle:@"OFF \xe7\x8e\xa9\xe5\xae\xb6\xe4\xb8\x8d\xe6\xad\xbb" forState:UIControlStateNormal];g_btnGodMode.backgroundColor=IMGUI_BTN_OFF;g_btnGodMode.layer.borderColor=IMGUI_RED.CGColor;}
    if(g_fullScreen){[g_btnFullScreen setTitle:@"ON  \xe5\x85\xa8\xe5\xb1\x8f\xe7\xa7\x92\xe6\x9d\x80" forState:UIControlStateNormal];g_btnFullScreen.backgroundColor=IMGUI_BTN_ON;g_btnFullScreen.layer.borderColor=IMGUI_GREEN.CGColor;}
    else{[g_btnFullScreen setTitle:@"OFF \xe5\x85\xa8\xe5\xb1\x8f\xe7\xa7\x92\xe6\x9d\x80" forState:UIControlStateNormal];g_btnFullScreen.backgroundColor=IMGUI_BTN_OFF;g_btnFullScreen.layer.borderColor=IMGUI_RED.CGColor;}
    if(g_exSkillAlways){[g_btnExSkillAlways setTitle:@"ON  \xe5\xa4\xa7\xe6\x8b\x9b\xe5\xa2\x9e\xe5\xbc\xba" forState:UIControlStateNormal];g_btnExSkillAlways.backgroundColor=IMGUI_BTN_ON;g_btnExSkillAlways.layer.borderColor=IMGUI_GREEN.CGColor;}
    else{[g_btnExSkillAlways setTitle:@"OFF \xe5\xa4\xa7\xe6\x8b\x9b\xe5\xa2\x9e\xe5\xbc\xba" forState:UIControlStateNormal];g_btnExSkillAlways.backgroundColor=IMGUI_BTN_OFF;g_btnExSkillAlways.layer.borderColor=IMGUI_RED.CGColor;}
    if(g_btnApplySkin){[g_btnApplySkin setTitle:@"\xe5\xba\x94\xe7\x94\xa8\xe7\x9a\xae\xe8\x82\xa4/\xe6\xad\xa6\xe5\x99\xa8" forState:UIControlStateNormal];g_btnApplySkin.backgroundColor=[UIColor colorWithRed:0.18 green:0.35 blue:0.55 alpha:0.95];g_btnApplySkin.layer.borderColor=IMGUI_ACCENT.CGColor;}
    if(g_btnScanSkin){
        if(g_skinIdsLoaded){[g_btnScanSkin setTitle:[NSString stringWithFormat:@"\xe5\xb7\xb2\xe6\x89\xab\xe6\x8f\x8f:%d\xe4\xb8\xaa\xe7\x9a\xae\xe8\x82\xa4",g_roleSkinCount] forState:UIControlStateNormal];g_btnScanSkin.backgroundColor=[UIColor colorWithRed:0.16 green:0.52 blue:0.28 alpha:0.95];}
        else{[g_btnScanSkin setTitle:@"\xe6\x89\xab\xe6\x8f\x8f\xe7\x9a\xae\xe8\x82\xa4ID" forState:UIControlStateNormal];g_btnScanSkin.backgroundColor=[UIColor colorWithRed:0.18 green:0.35 blue:0.55 alpha:0.95];}
        g_btnScanSkin.layer.borderColor=IMGUI_ACCENT.CGColor;
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

@implementation JYJHActionHandler
+(instancetype)shared{static JYJHActionHandler *s;static dispatch_once_t o;dispatch_once(&o,^{s=[[self alloc]init];});return s;}
-(void)onIgnoreUnlock{
    g_ignoreUnlock=!g_ignoreUnlock;
    if(g_ignoreUnlock&&!g_hUnlock){findIL2CPP();hookOneFunc(g_fUnlock,hUnlock,(void**)&g_oUnlock,&g_hUnlock,"Unlock");}
    refreshBtns();jlog(@"Toggle Unlock: %d",g_ignoreUnlock);
}
-(void)onExSkillNoCD{
    g_exSkillNoCD=!g_exSkillNoCD;
    if(g_exSkillNoCD){findIL2CPP();
        if(!g_hIsReady)hookOneFunc(g_fIsReady,hIsReady,(void**)&g_oIsReady,&g_hIsReady,"IsReady");
        if(!g_hAttackCanUse)hookOneFunc(g_fAttackCanUse,hAttackCanUse,(void**)&g_oAttackCanUse,&g_hAttackCanUse,"AttackCanUse");
    }
    refreshBtns();jlog(@"Toggle NoCD: %d",g_exSkillNoCD);
}
-(void)onGodMode{
    g_godMode=!g_godMode;
    if(g_godMode){findIL2CPP();
        if(!g_hAttackCanUse)hookOneFunc(g_fAttackCanUse,hAttackCanUse,(void**)&g_oAttackCanUse,&g_hAttackCanUse,"AttackCanUse");
        if(!g_hIsReady)hookOneFunc(g_fIsReady,hIsReady,(void**)&g_oIsReady,&g_hIsReady,"IsReady");
        if(!g_hCanBeAttack)hookOneFunc(g_fCanBeAttack,hCanBeAttack,(void**)&g_oCanBeAttack,&g_hCanBeAttack,"CanBeAttack");
        if(!g_hDamage)hookOneFunc(g_fDamage,hDamage,(void**)&g_oDamage,&g_hDamage,"Damage");
    }
    refreshBtns();jlog(@"Toggle God: %d",g_godMode);
}
-(void)onFullScreen{
    g_fullScreen=!g_fullScreen;
    if(g_fullScreen){findIL2CPP();
        if(!g_hIntersects)hookOneFunc(g_fIntersects,hIntersects,(void**)&g_oIntersects,&g_hIntersects,"Intersects");
        if(!g_hCheckHit)hookOneFunc(g_fCheckHit,hCheckHit,(void**)&g_oCheckHit,&g_hCheckHit,"CheckHit(Z)");
        if(!g_hDamage)hookOneFunc(g_fDamage,hDamage,(void**)&g_oDamage,&g_hDamage,"Damage");
        if(!g_hHitSystemUpdate)hookOneFunc(g_fHitSystemUpdate,hHitSystemUpdate,(void**)&g_oHitSystemUpdate,&g_hHitSystemUpdate,"HitSystem.Update");
        g_enemyCount=0;
        jlog(@"FullScreen ON: Intersects+CheckHit+HitSysUpdate enabled");
    }else{jlog(@"FullScreen OFF");}
    refreshBtns();
}
-(void)onExSkillAlways{
    g_exSkillAlways=!g_exSkillAlways;
    if(g_exSkillAlways){findIL2CPP();
        // v61: Hook TryTriggerExSkill(8参) 诊断大招触发
        if(!g_hTryTriggerExSkill && g_fTryTriggerExSkill)
            hookOneFunc(g_fTryTriggerExSkill,hTryTriggerExSkill,(void**)&g_oTryTriggerExSkill,&g_hTryTriggerExSkill,"TryTriggerExSkill");
        // v61: 同时Hook IsExSkillInCD(3参) 诊断CD检测
        if(!g_hIsExSkillInCD && g_fIsExSkillInCD)
            hookOneFunc(g_fIsExSkillInCD,hIsExSkillInCD,(void**)&g_oIsExSkillInCD,&g_hIsExSkillInCD,"IsExSkillInCD");
    }
    refreshBtns();jlog(@"Toggle ExSkillAlways: %d TryTrigger=%p IsCD=%p",g_exSkillAlways,g_fTryTriggerExSkill,g_fIsExSkillInCD);
}
-(void)sliderChanged:(UISlider*)s{g_damageLimit=(int)s.value;g_sliderLabel.text=[NSString stringWithFormat:@"\xe4\xbc\xa4\xe5\xae\xb3\xe4\xb8\x8a\xe9\x99\x90: %d",g_damageLimit];}
-(void)skinSliderChanged:(UISlider*)s{g_skinId=(int)s.value;g_skinLabel.text=[NSString stringWithFormat:@"\xe7\x9a\xae\xe8\x82\xa4" "ID: %d",g_skinId];}
-(void)weaponSliderChanged:(UISlider*)s{g_weaponId=(int)s.value;g_weaponLabel.text=[NSString stringWithFormat:@"\xe6\xad\xa6\xe5\x99\xa8" "ID: %d",g_weaponId];}
-(void)onApplySkin{
    if(!g_hGetSkinId && g_fGetSkinId) hookOneFunc(g_fGetSkinId,hGetSkinId,(void**)&g_oGetSkinId,&g_hGetSkinId,"get_SkinId");
    g_appliedSkinId=g_skinId; g_appliedWeaponId=g_weaponId;
    if(g_playerActorObj){
        uint8_t *p=(uint8_t*)g_playerActorObj;
        int32_t curSkin=0,curWeapon=0;
        memcpy(&curSkin,p+0x110,4); memcpy(&curWeapon,p+0x114,4);
        jlog(@"ApplySkin: cur skin=%d weapon=%d -> new skin=%d weapon=%d",curSkin,curWeapon,g_skinId,g_weaponId);
        memcpy(p+0x110,&g_skinId,4); memcpy(p+0x114,&g_weaponId,4);
    } else jlog(@"ApplySkin: Actor not found yet");
}
-(void)onDumpSkinIds{
    if(!g_classGameEntry||!g_classConfigComponent){jlog(@"DumpSkin: classes not found, running findIL2CPP...");findIL2CPP();}
    if(g_skinIdsLoaded){jlog(@"DumpSkin: already scanned, role=%d weapon=%d",g_roleSkinCount,g_weaponSkinCount);refreshBtns();return;}
    jlog(@"DumpSkin: starting (via GameEntry._config)...");
    scanSkinIds();
    refreshBtns();
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
    UILabel *l=[[UILabel alloc]initWithFrame:CGRectMake(0,0,36,36)];l.text=@"\xe2\x87\x98";l.textColor=[UIColor whiteColor];l.font=[UIFont systemFontOfSize:18];l.textAlignment=NSTextAlignmentCenter;[self addSubview:l];
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
    UILabel*l=[[UILabel alloc]initWithFrame:CGRectMake(0,0,40,40)];l.text=@"\xe5\x89\x91";l.textColor=[UIColor whiteColor];l.font=[UIFont boldSystemFontOfSize:18];l.textAlignment=NSTextAlignmentCenter;[self addSubview:l];
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
    UILabel *tl=[[UILabel alloc]initWithFrame:CGRectMake(10,6,g_panelW-20,20)];tl.text=@"\xe5\x89\x91\xe5\xbd\xb1\xe6\xb1\x9f\xe6\xb9\x96 v61.0";tl.textColor=IMGUI_ACCENT;tl.font=[UIFont boldSystemFontOfSize:15];tl.textAlignment=NSTextAlignmentCenter;[tb addSubview:tl];
    UIScrollView *sv=[[UIScrollView alloc]initWithFrame:CGRectMake(0,32,g_panelW,g_panelH-32)];
    sv.showsVerticalScrollIndicator=YES;sv.delaysContentTouches=NO;sv.canCancelContentTouches=YES;sv.scrollEnabled=YES;sv.userInteractionEnabled=YES;
    [outer addSubview:sv]; g_scrollView=sv;
    CGFloat bx=12,bw=g_panelW-24,bh=24,by0=4,bdy=28;
    CGFloat contentH=by0+bdy*5+60+188;
    sv.contentSize=CGSizeMake(g_panelW,contentH);
    g_btnIgnoreUnlock=mkBtn(CGRectMake(bx,by0,bw,bh),@selector(onIgnoreUnlock));[sv addSubview:g_btnIgnoreUnlock];
    g_btnExSkillNoCD=mkBtn(CGRectMake(bx,by0+bdy,bw,bh),@selector(onExSkillNoCD));[sv addSubview:g_btnExSkillNoCD];
    g_btnGodMode=mkBtn(CGRectMake(bx,by0+bdy*2,bw,bh),@selector(onGodMode));[sv addSubview:g_btnGodMode];
    g_btnFullScreen=mkBtn(CGRectMake(bx,by0+bdy*3,bw,bh),@selector(onFullScreen));[sv addSubview:g_btnFullScreen];
    g_btnExSkillAlways=mkBtn(CGRectMake(bx,by0+bdy*4,bw,bh),@selector(onExSkillAlways));[sv addSubview:g_btnExSkillAlways];
    CGFloat s1Y=by0+bdy*5;UIView *s1=[[UIView alloc]initWithFrame:CGRectMake(bx,s1Y,bw,1)];s1.backgroundColor=IMGUI_BORDER;[sv addSubview:s1];
    CGFloat sy=s1Y+8;
    g_sliderLabel=[[UILabel alloc]initWithFrame:CGRectMake(bx,sy,bw,18)];g_sliderLabel.text=[NSString stringWithFormat:@"\xe4\xbc\xa4\xe5\xae\xb3\xe4\xb8\x8a\xe9\x99\x90: %d",g_damageLimit];g_sliderLabel.textColor=IMGUI_DIMTEXT;g_sliderLabel.font=[UIFont systemFontOfSize:12];[sv addSubview:g_sliderLabel];
    g_slider=[[UISlider alloc]initWithFrame:CGRectMake(bx,sy+20,bw,28)];g_slider.minimumValue=1;g_slider.maximumValue=5000;g_slider.value=g_damageLimit;[g_slider addTarget:[JYJHActionHandler shared] action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];[sv addSubview:g_slider];
    CGFloat s2Y=sy+52;UIView *s2=[[UIView alloc]initWithFrame:CGRectMake(bx,s2Y,bw,1)];s2.backgroundColor=IMGUI_BORDER;[sv addSubview:s2];
    CGFloat ssy=s2Y+6;
    UILabel *secT=[[UILabel alloc]initWithFrame:CGRectMake(bx,ssy,bw,18)];secT.text=@"\xe7\x9a\xae\xe8\x82\xa4/\xe6\xad\xa6\xe5\x99\xa8" "(\xe6\x88\x98\xe6\x96\x97\xe4\xb8\xad\xe5\x86\x99" "Actor" "\xe5\xad\x97\xe6\xae\xb5)";secT.textColor=IMGUI_ACCENT;secT.font=[UIFont boldSystemFontOfSize:11];[sv addSubview:secT];
    g_skinLabel=[[UILabel alloc]initWithFrame:CGRectMake(bx,ssy+20,bw,18)];g_skinLabel.text=[NSString stringWithFormat:@"\xe7\x9a\xae\xe8\x82\xa4" "ID: %d",g_skinId];g_skinLabel.textColor=IMGUI_DIMTEXT;g_skinLabel.font=[UIFont systemFontOfSize:12];[sv addSubview:g_skinLabel];
    g_skinSlider=[[UISlider alloc]initWithFrame:CGRectMake(bx,ssy+38,bw,28)];g_skinSlider.minimumValue=0;g_skinSlider.maximumValue=2000;g_skinSlider.value=g_skinId;[g_skinSlider addTarget:[JYJHActionHandler shared] action:@selector(skinSliderChanged:) forControlEvents:UIControlEventValueChanged];[sv addSubview:g_skinSlider];
    g_weaponLabel=[[UILabel alloc]initWithFrame:CGRectMake(bx,ssy+68,bw,18)];g_weaponLabel.text=[NSString stringWithFormat:@"\xe6\xad\xa6\xe5\x99\xa8" "ID: %d",g_weaponId];g_weaponLabel.textColor=IMGUI_DIMTEXT;g_weaponLabel.font=[UIFont systemFontOfSize:12];[sv addSubview:g_weaponLabel];
    g_weaponSlider=[[UISlider alloc]initWithFrame:CGRectMake(bx,ssy+86,bw,28)];g_weaponSlider.minimumValue=0;g_weaponSlider.maximumValue=2000;g_weaponSlider.value=g_weaponId;[g_weaponSlider addTarget:[JYJHActionHandler shared] action:@selector(weaponSliderChanged:) forControlEvents:UIControlEventValueChanged];[sv addSubview:g_weaponSlider];
    g_btnApplySkin=mkBtn(CGRectMake(bx,ssy+118,bw,bh),@selector(onApplySkin));[sv addSubview:g_btnApplySkin];
    g_btnScanSkin=mkBtn(CGRectMake(bx,ssy+146,bw,bh),@selector(onDumpSkinIds));[sv addSubview:g_btnScanSkin];
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
    jlog(@"========== JYJH v61.0 ==========");
    jlog(@"iOS %@",[[UIDevice currentDevice] systemVersion]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(5.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        jlog(@"5s delay done"); applyAllHooks();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{setupUI();});
    });
}
