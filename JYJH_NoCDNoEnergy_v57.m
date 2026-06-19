/**
 * v57.0 - 修复扫描皮肤ID卡死 + 改用直接内存读取
 * v56问题:
 *   scanSkinIds()调用GetRoleSkinById(1~2000), 每次都是IL2CPP方法调用
 *   在主线程同步循环2000次→卡死游戏
 * v57方案:
 *   1. 完全移除GetRoleSkinById循环扫描方案
 *   2. 改为直接从cfg.Tables实例内存读取TbRoleSkin._dataList
 *      - 通过il2cpp_class_get_static_field_data或il2cpp_field_static_get_value找Tables实例
 *      - Tables.TbRoleSkin at +0x230, TbWeaponSkin at +0x248
 *      - TbRoleSkin._dataList(List<RoleSkin>) at +0x18
 *      - 遍历List读取每个RoleSkin.Id at +0x10(它是class,dump偏移=实际偏移)
 *   3. 如果找不到Tables实例,只打印日志不卡死
 *   4. 保留v55的HitSystem偏移修正(0x48/0x50)和皮肤修改修复
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

static BOOL g_ignoreUnlock=NO, g_exSkillNoCD=NO, g_godMode=NO, g_fullScreen=NO;
static int g_damageLimit=100, g_skinId=0, g_weaponId=0;

typedef BOOL (*BoolFunc3)(void*,int,int);
typedef int (*IntFunc1)(void*);
typedef BOOL (*BoolFunc4)(void*,int,void*,void*);
typedef BOOL (*CanBeAttackFunc)(void*);
typedef int64_t (*DamageFunc)(void*,void*,void*,void*,void*,int32_t,int32_t,BOOL,int32_t,int32_t,void*,void*);
typedef int64_t (*DecreaseHPFunc)(void*,void*,void*,void*,int64_t);
typedef BOOL (*IntersectsFunc)(void*,void*);
typedef int32_t (*CheckHitFunc)(void*,void*);
typedef void (*MonsterDeadSignalFunc)(void*,void*,void*,void*,int32_t); // Frame,entity,atk,DeathEnum

static void *g_fUnlock=NULL; static BoolFunc3 g_oUnlock=NULL; static BOOL g_hUnlock=NO;
static void *g_fLimitDmg=NULL; static IntFunc1 g_oLimitDmg=NULL; static BOOL g_hLimitDmg=NO;
static void *g_fIsReady=NULL; static BoolFunc4 g_oIsReady=NULL; static BOOL g_hIsReady=NO;
static void *g_fAttackCanUse=NULL; static BoolFunc4 g_oAttackCanUse=NULL; static BOOL g_hAttackCanUse=NO;
static void *g_fCanBeAttack=NULL; static CanBeAttackFunc g_oCanBeAttack=NULL; static BOOL g_hCanBeAttack=NO;
static void *g_fDamage=NULL; static DamageFunc g_oDamage=NULL; static BOOL g_hDamage=NO;
static void *g_fIntersects=NULL; static IntersectsFunc g_oIntersects=NULL; static BOOL g_hIntersects=NO;
static void *g_fCheckHit=NULL; static CheckHitFunc g_oCheckHit=NULL; static BOOL g_hCheckHit=NO;
static void *g_fMonsterDead=NULL; // MonsterDeadSignal function pointer

// v53: HitSystem.Update Hook - 扩大HitBoundZ实现全屏
typedef void (*HitSystemUpdateFunc)(void*,void*); // (HitSystem*, Frame*)
static void *g_fHitSystemUpdate=NULL; static HitSystemUpdateFunc g_oHitSystemUpdate=NULL; static BOOL g_hHitSystemUpdate=NO;

// v43: DecreaseHP直接保存函数指针(不Hook, 只调用原始函数)
static DecreaseHPFunc g_origDecreaseHP = NULL;
static void *g_classActor=NULL;

// v54: 皮肤修改相关
static void *g_playerActorObj=NULL; // Actor对象实例
static int32_t g_appliedSkinId=0, g_appliedWeaponId=0;
// LobbyActorData.UpdatePart at 0x2bfb050
typedef void (*UpdatePartFunc)(void*,int32_t,int32_t,int32_t);
static void *g_fUpdatePart=NULL;

// v55: Hook Actor.get_SkinId 来拦截Actor对象并返回修改值
// v54问题: isLocal偏移+0x10d读出垃圾值(isLocal=116,skin=-1042326430)
// 修复: 不用isLocal判断,直接捕获第一个调用get_SkinId的self(通常是玩家)
// 如果多次调用不同对象,用CF的Camp字段(+0x44)来区分玩家(Camp=0)
typedef int32_t (*GetSkinIdFunc)(void*);
static void *g_fGetSkinId=NULL; static GetSkinIdFunc g_oGetSkinId=NULL; static BOOL g_hGetSkinId=NO;
static int g_skinIdHookLC=0;
static int32_t hGetSkinId(void *self) {
    // 保存Actor对象引用 - 第一个调用的就是玩家(游戏初始化时先加载自己的角色)
    if(self && !g_playerActorObj) {
        g_playerActorObj=self;
        int32_t skinId=0,weaponId=0;
        memcpy(&skinId,(uint8_t*)self+0x110,4);
        memcpy(&weaponId,(uint8_t*)self+0x114,4);
        jlog(@"FOUND player Actor=%p skin=%d weapon=%d",self,skinId,weaponId);
    }
    // 记录日志(前5次)
    if(g_skinIdHookLC<5){g_skinIdHookLC++;jlog(@"get_SkinId: self=%p isPlayer=%d",self,self==g_playerActorObj);}
    int32_t r=g_oGetSkinId?g_oGetSkinId(self):0;
    // 如果设置了新皮肤ID,返回新值
    if(self==g_playerActorObj && g_appliedSkinId>0) return g_appliedSkinId;
    return r;
}

// v55: HitSystem.collBound修正偏移
// dump: collBound at 0x38. FPBounds2是值类型(无IL2CPP header),直接嵌套在HitSystem中
// FPBounds2 layout: Center.x(FP=8B) + Center.y(FP=8B) + Extents.x(FP=8B) + Extents.y(FP=8B) = 32B
// dump偏移0x38就是collBound字段的实际偏移(值类型不减0x10)
// Center.x.RawValue = self+0x38
// Center.y.RawValue = self+0x40
// Extents.x.RawValue = self+0x48
// Extents.y.RawValue = self+0x50
#define HITSYS_COLLBOUND_OFF 0x38
#define HITSYS_EXTENTS_X_OFF (HITSYS_COLLBOUND_OFF+16)  // 0x48
#define HITSYS_EXTENTS_Y_OFF (HITSYS_COLLBOUND_OFF+24)  // 0x50
// 保存collBound Extents原始值
static int64_t g_savedExtX=0, g_savedExtY=0;

static void *g_playerCF=NULL, *g_playerEntity=NULL; static BOOL g_playerCFLearned=NO;
#define MAX_ENEMIES 64
static void *g_enemyCFs[MAX_ENEMIES], *g_enemyEntities[MAX_ENEMIES]; static int g_enemyCount=0;

// v57: 皮肤ID列表 - 直接从内存读取,不调用IL2CPP方法(避免卡死)
// 访问路径: GameEntryMain._config(static at 0xa8) → ConfigComponent.Tables(+0x28) → cfg.Tables
//   → Tables.TbRoleSkin(+0x230) → TbRoleSkin._dataList(+0x18) → List<RoleSkin>
//   → List._items(+0x10) → Array → length(+0x10), data from +0x20 (8B ptrs)
//   → RoleSkin.Id(+0x10, class so dump=actual)
// GameEntryMain继承SingletonMono<T>, static instance at 0x0
// GameEntryMain._config is static at 0xa8
// 通过il2cpp_class_get_static_field_data获取GameEntryMain类的静态数据区
typedef void* (*Il2CppClassGetStaticFieldDataFunc)(void*);
static void *g_classGameEntryMain=NULL;
static void scanSkinIds(void) {
    if(g_skinIdsLoaded) return;
    g_skinIdsLoaded=YES;
    g_roleSkinCount=0; g_weaponSkinCount=0;
    
    // v57: 通过GameEntryMain静态字段找到ConfigComponent→Tables→TbRoleSkin
    void *h=dlopen(NULL,RTLD_LAZY);
    Il2CppClassGetStaticFieldDataFunc get_static_data=dlsym(h,"il2cpp_class_get_static_field_data");
    if(!get_static_data){jlog(@"ScanSkin: il2cpp_class_get_static_field_data not found");return;}
    
    // 需要GameEntryMain的class指针 - 在findIL2CPP中搜索
    if(!g_classGameEntryMain){jlog(@"ScanSkin: GameEntryMain class not found");return;}
    
    // 获取GameEntryMain的静态数据区
    void *staticData=get_static_data(g_classGameEntryMain);
    if(!staticData){jlog(@"ScanSkin: GameEntryMain static data is NULL");return;}
    
    // GameEntryMain._config at static+0xa8 (static field, dump offset = actual for class statics)
    // 注意: static field的偏移规则 - dump中0xa8是相对于静态数据区的偏移
    // 但IL2CPP的static field data区从0x0开始, dump偏移0xa8可能需要减0x10
    // 先试不减0x10
    void *configComp=NULL;
    memcpy(&configComp,(uint8_t*)staticData+0xa8,8);
    jlog(@"ScanSkin: staticData=%p configComp=%p",staticData,configComp);
    if(!configComp){
        // 试减0x10
        memcpy(&configComp,(uint8_t*)staticData+0x98,8);
        jlog(@"ScanSkin: retry -0x10: configComp=%p",configComp);
    }
    if(!configComp){jlog(@"ScanSkin: ConfigComponent is NULL");return;}
    
    // ConfigComponent.Tables at +0x28 (class field, dump=actual)
    void *tables=NULL;
    memcpy(&tables,(uint8_t*)configComp+0x28,8);
    jlog(@"ScanSkin: tables=%p",tables);
    if(!tables){jlog(@"ScanSkin: Tables is NULL");return;}
    
    // Tables.TbRoleSkin at +0x230 (class field, dump=actual)
    void *tbRoleSkin=NULL;
    memcpy(&tbRoleSkin,(uint8_t*)tables+0x230,8);
    jlog(@"ScanSkin: tbRoleSkin=%p",tables);
    if(!tbRoleSkin){jlog(@"ScanSkin: TbRoleSkin is NULL");return;}
    
    // TbRoleSkin._dataList at +0x18 (class field, dump=actual)
    void *dataList=NULL;
    memcpy(&dataList,(uint8_t*)tbRoleSkin+0x18,8);
    jlog(@"ScanSkin: dataList=%p",dataList);
    if(!dataList){jlog(@"ScanSkin: _dataList is NULL");return;}
    
    // List<RoleSkin>._items at +0x10, _size at +0x18
    void *itemsArray=NULL; int32_t listSize=0;
    memcpy(&itemsArray,(uint8_t*)dataList+0x10,8);
    memcpy(&listSize,(uint8_t*)dataList+0x18,4);
    jlog(@"ScanSkin: itemsArray=%p listSize=%d",itemsArray,listSize);
    if(!itemsArray||listSize<=0){jlog(@"ScanSkin: List empty");return;}
    
    // Array: length at +0x10, data from +0x20 (each element is 8B pointer to RoleSkin)
    int32_t arrayLen=0;
    memcpy(&arrayLen,(uint8_t*)itemsArray+0x10,4);
    jlog(@"ScanSkin: arrayLen=%d",arrayLen);
    
    int count=0;
    int maxScan=(listSize<MAX_SKIN_IDS)?listSize:MAX_SKIN_IDS;
    for(int i=0;i<maxScan&&i<arrayLen;i++){
        void *roleSkinPtr=NULL;
        memcpy(&roleSkinPtr,(uint8_t*)itemsArray+0x20+i*8,8);
        if(!roleSkinPtr)continue;
        // RoleSkin.Id at +0x10 (class, dump=actual)
        int32_t skinId=0;
        memcpy(&skinId,(uint8_t*)roleSkinPtr+0x10,4);
        if(skinId>0){
            g_roleSkinIds[g_roleSkinCount++]=skinId;
            count++;
        }
    }
    jlog(@"ScanSkinIds: found %d role skin IDs from TbRoleSkin._dataList",g_roleSkinCount);
    for(int i=0;i<g_roleSkinCount&&i<20;i++) jlog(@"  RoleSkin[%d]=%d",i,g_roleSkinIds[i]);
    
    // 同样读取TbWeaponSkin
    void *tbWeaponSkin=NULL;
    memcpy(&tbWeaponSkin,(uint8_t*)tables+0x248,8);
    if(tbWeaponSkin){
        void *wDataList=NULL;
        memcpy(&wDataList,(uint8_t*)tbWeaponSkin+0x18,8);
        if(wDataList){
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
static int g_dmgLC=0, g_fullDmgLC=0;
static int g_tablesSkipLC=0;
static int64_t hDamage(void *f,void *atkEnt,void *atkCF,void *tgtEnt,void *tgtCF,
    int32_t hitEid,int32_t hitSnd,BOOL isR,int32_t sBtn,int32_t sPart,void *hurtF,void *exS){
    BOOL tgtP=(tgtCF&&isPlayerCF(tgtCF)), atkP=(atkCF&&isPlayerCF(atkCF));
    if(atkP&&atkEnt)g_playerEntity=atkEnt;
    if(tgtCF&&!tgtP&&tgtEnt)trackEnemy(tgtCF,tgtEnt);
    if(g_godMode&&tgtP){if(g_dmgLC<20){g_dmgLC++;jlog(@"Dmg:Player->0");}return 0;}
    if(!g_oDamage)return 0;
    int64_t r=g_oDamage(f,atkEnt,atkCF,tgtEnt,tgtCF,hitEid,hitSnd,isR,sBtn,sPart,hurtF,exS);
    if(atkP&&r>0){
        if(g_dmgLC<20){g_dmgLC++;jlog(@"Dmg[%d]=%lld enemies=%d",g_dmgLC,r,g_enemyCount);}
        // v53: 禁用DecreaseHP扩散(破坏帧同步), 全屏效果改由HitSystem.Update扩大HitBoundZ实现
    }
    return r;
}
static BOOL hIntersects(void *s,void *o){if(g_fullScreen)return YES;return g_oIntersects?g_oIntersects(s,o):NO;}
static int32_t hCheckHit(void *f,void *cb){if(g_fullScreen)return 1;return g_oCheckHit?g_oCheckHit(f,cb):0;}

// v54: HitSystem.Update Hook - 扩大collBound Extents实现全屏
// v53遍历组件的方案导致卡死,改为只修改HitSystem.collBound的Extents
static int g_hitSysLC=0;
static void hHitSystemUpdate(void *self, void *framePtr) {
    if(!g_fullScreen || !self) {
        if(g_oHitSystemUpdate) g_oHitSystemUpdate(self, framePtr);
        return;
    }
    // 保存collBound Extents原始值
    uint8_t *p=(uint8_t*)self;
    memcpy(&g_savedExtX, p+HITSYS_EXTENTS_X_OFF, 8);
    memcpy(&g_savedExtY, p+HITSYS_EXTENTS_Y_OFF, 8);
    // 设为超大值 - FP定点数, RawValue=0x7FFFFFFFFFFFFFFF
    int64_t huge=0x7FFFFFFFFFFFFFFF;
    memcpy(p+HITSYS_EXTENTS_X_OFF, &huge, 8);
    memcpy(p+HITSYS_EXTENTS_Y_OFF, &huge, 8);
    // 调用原始Update
    if(g_oHitSystemUpdate) g_oHitSystemUpdate(self, framePtr);
    // 恢复
    memcpy(p+HITSYS_EXTENTS_X_OFF, &g_savedExtX, 8);
    memcpy(p+HITSYS_EXTENTS_Y_OFF, &g_savedExtY, 8);
    if(g_hitSysLC<10){g_hitSysLC++;jlog(@"HitSysUpdate: extX=%lld extY=%lld",g_savedExtX,g_savedExtY);}
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
typedef void* (*Il2CppClassGetFieldFromName)(void*,const char*);
typedef void (*Il2CppFieldStaticGetValue)(void*,void*);
typedef void* (*Il2CppClassGetFields)(void*,void**);
typedef const char* (*Il2CppFieldGetName)(void*);
typedef size_t (*Il2CppFieldGetOffset)(void*);
typedef uint32_t (*Il2CppFieldGetFlags)(void*);
typedef const char* (*Il2CppClassGetNamespace)(void*);

static void findIL2CPP(void) {
    jlog(@"=== v57.0 IL2CPP Search ===");
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
    Il2CppClassGetFieldFromName class_get_field=dlsym(h,"il2cpp_class_get_field_from_name");
    Il2CppFieldStaticGetValue field_static_get=dlsym(h,"il2cpp_field_static_get_value");
    Il2CppClassGetFields get_fields=dlsym(h,"il2cpp_class_get_fields");
    Il2CppFieldGetName field_get_name=dlsym(h,"il2cpp_field_get_name");
    Il2CppFieldGetOffset field_get_offset=dlsym(h,"il2cpp_field_get_offset");
    Il2CppFieldGetFlags field_get_flags=dlsym(h,"il2cpp_field_get_flags");
    Il2CppClassGetNamespace class_get_namespace=dlsym(h,"il2cpp_class_get_namespace");
    if(!domain_get||!method_name){jlog(@"IL2CPP APIs not found");return;}
    void *domain=domain_get(); if(!domain)return;
    size_t assemCount=0; void **assemblies=get_assemblies(domain,&assemCount);
    if(!assemblies)return;
    jlog(@"assemblies=%p count=%zu",assemblies,assemCount);
    int found=0,totalMethods=0; void *classTables=NULL;
    for(size_t a=0;a<assemCount;a++){
        void *img=get_image(assemblies[a]); if(!img)continue;
        size_t cnt=class_count?class_count(img):0;
        for(size_t c=0;c<cnt;c++){
            void *klass=get_class(img,c); if(!klass)continue;
            const char *cn=class_name_func?class_name_func(klass):NULL;
            if(cn&&strcmp(cn,"Actor")==0&&!g_classActor){
                g_classActor=klass; jlog(@"FOUND class Actor=%p",klass);
            }
            // v44: Tables类 - 用namespace过滤找cfg.Tables(不是Dictionary内部Tables)
            if(cn&&strcmp(cn,"Tables")==0&&!classTables){
                // 检查namespace是否为"cfg"
                const char *ns=class_get_namespace?class_get_namespace(klass):NULL;
                if(ns&&strcmp(ns,"cfg")!=0){
                    if(g_tablesSkipLC<5){g_tablesSkipLC++;jlog(@"SKIP Tables ns=%s (want cfg)",ns?:"?");}
                    continue; // 跳过非cfg命名空间的Tables类
                }
                classTables=klass;
                jlog(@"FOUND class Tables=%p ns=%s",klass,ns?:"?");
                // v57: Tables通过GameEntryMain._config访问,不需要直接搜索实例
            }
            // v57: 搜索GameEntryMain类 - 用于获取ConfigComponent→Tables
            if(cn&&strcmp(cn,"GameEntryMain")==0&&!g_classGameEntryMain){
                g_classGameEntryMain=klass;
                jlog(@"FOUND class GameEntryMain=%p",klass);
            }
            // 搜索方法
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
                else if(strcmp(n,"DecreaseHP")==0&&pc==5){
                    // v43: 直接保存原始函数指针,不Hook
                    if(!g_origDecreaseHP){
                        g_origDecreaseHP=(DecreaseHPFunc)fa;
                        jlog(@"FOUND %s.DecreaseHP p=%u %p (saved as orig, NOT hooked)",cn?:"?",n,pc,fa);
                    }
                }
                else if(strcmp(n,"Intersects")==0&&pc==1&&cn&&strstr(cn,"FPBounds2")!=NULL&&!g_fIntersects){g_fIntersects=fa;found++;jlog(@"FOUND %s.%s p=%u %p",cn?:"?",n,pc,fa);}
                else if(strcmp(n,"CheckPlayerHitCollider")==0&&pc==2&&!g_fCheckHit){g_fCheckHit=fa;found++;jlog(@"FOUND %s.%s p=%u %p",cn?:"?",n,pc,fa);}
                // v50: 搜索MonsterDeadSignal(Frame,EntityRef,EntityRef,DeathEnum) 4参数
                else if(strcmp(n,"MonsterDeadSignal")==0&&pc==4&&!g_fMonsterDead){g_fMonsterDead=fa;found++;jlog(@"FOUND %s.%s p=%u %p",cn?:"?",n,pc,fa);}
                // v53: 搜索HitSystem.Update - 碰撞检测主循环
                else if(strcmp(n,"Update")==0&&pc==1&&cn&&strcmp(cn,"HitSystem")==0&&!g_fHitSystemUpdate){g_fHitSystemUpdate=fa;found++;jlog(@"FOUND %s.%s p=%u %p",cn?:"?",n,pc,fa);}
                // v54: 搜索LobbyActorData.UpdatePart - 皮肤/武器刷新
                else if(strcmp(n,"UpdatePart")==0&&pc==3&&!g_fUpdatePart){g_fUpdatePart=fa;found++;jlog(@"FOUND %s.%s p=%u %p",cn?:"?",n,pc,fa);}
                // v54: 搜索Actor.get_SkinId - 拦截Actor对象
                else if(strcmp(n,"get_SkinId")==0&&pc==0&&cn&&strcmp(cn,"Actor")==0&&!g_fGetSkinId){g_fGetSkinId=fa;found++;jlog(@"FOUND %s.%s p=%u %p",cn?:"?",n,pc,fa);}
                // v57: 不再搜索GetRoleSkinById - 改用直接内存读取TbRoleSkin._dataList
            }
        }
    }
    jlog(@"Scanned %d methods, found %d targets, origDecreaseHP=%p",totalMethods,found,g_origDecreaseHP);
    // v56: 移除自动scanSkinIds()调用 — 在主线程遍历2000次IL2CPP方法导致启动卡死
    // 改为用户手动触发(onDumpSkinIds按钮)
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
static UIScrollView *g_scrollView=nil; // v47: 保存scrollView引用用于resize
static UIButton *g_btnIgnoreUnlock=nil,*g_btnExSkillNoCD=nil,*g_btnGodMode=nil,*g_btnFullScreen=nil,*g_btnApplySkin=nil,*g_btnScanSkin=nil;
static UISlider *g_slider=nil,*g_skinSlider=nil,*g_weaponSlider=nil;
static UILabel *g_sliderLabel=nil,*g_skinLabel=nil,*g_weaponLabel=nil;
static BOOL g_panelOpen=NO;
// 面板大小
static CGFloat g_panelW=360, g_panelH=520;
static UIView *g_resizeHandle=nil, *g_resizeHandleTop=nil; // v52: 右上角缩放

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
-(void)onDumpSkinIds;
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
    // Apply skin button - 始终显示
    if(g_btnApplySkin){[g_btnApplySkin setTitle:@"\xe5\xba\x94\xe7\x94\xa8\xe7\x9a\xae\xe8\x82\xa4/\xe6\xad\xa6\xe5\x99\xa8" forState:UIControlStateNormal];g_btnApplySkin.backgroundColor=[UIColor colorWithRed:0.18 green:0.35 blue:0.55 alpha:0.95];g_btnApplySkin.layer.borderColor=IMGUI_ACCENT.CGColor;}
    // v56: 扫描皮肤ID按钮
    if(g_btnScanSkin){
        if(g_skinIdsLoaded){[g_btnScanSkin setTitle:[NSString stringWithFormat:@"\xe5\xb7\xb2\xe6\x89\xab\xe6\x8f\x8f:%d\xe4\xb8\xaa\xe7\x9a\xae\xe8\x82\xa4",g_roleSkinCount] forState:UIControlStateNormal];g_btnScanSkin.backgroundColor=[UIColor colorWithRed:0.16 green:0.52 blue:0.28 alpha:0.95];}
        else{[g_btnScanSkin setTitle:@"\xe6\x89\xab\xe6\x8f\x8f\xe7\x9a\xae\xe8\x82\xa4ID" forState:UIControlStateNormal];g_btnScanSkin.backgroundColor=[UIColor colorWithRed:0.18 green:0.35 blue:0.55 alpha:0.95];}
        g_btnScanSkin.layer.borderColor=IMGUI_ACCENT.CGColor;
    }
}

static void layoutPanelCenter(void){
    if(!g_panel)return;
    CGRect sc=[UIScreen mainScreen].bounds;
    CGFloat px=(sc.size.width-g_panelW)/2;
    CGFloat py=80; // v44
    g_panel.frame=CGRectMake(px,py,g_panelW,g_panelH);
}

static void togglePanel(void){
    g_panelOpen=!g_panelOpen;g_panel.hidden=!g_panelOpen;
    // v53: resize handle跟随面板显示/隐藏
    g_resizeHandle.hidden=!g_panelOpen;
    g_resizeHandleTop.hidden=!g_panelOpen;
    if(g_panelOpen){
        layoutPanelCenter();
        // 更新resize handle位置到面板位置
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
    refreshBtns();jlog(@"Toggle God: %d decHP=%p",g_godMode,g_origDecreaseHP);
}
-(void)onFullScreen{
    g_fullScreen=!g_fullScreen;
    if(g_fullScreen){findIL2CPP();
        if(!g_hIntersects)hookOneFunc(g_fIntersects,hIntersects,(void**)&g_oIntersects,&g_hIntersects,"Intersects");
        if(!g_hCheckHit)hookOneFunc(g_fCheckHit,hCheckHit,(void**)&g_oCheckHit,&g_hCheckHit,"CheckHit(Z)");
        if(!g_hDamage)hookOneFunc(g_fDamage,hDamage,(void**)&g_oDamage,&g_hDamage,"Damage");
        // v53: Hook HitSystem.Update扩大HitBoundZ
        if(!g_hHitSystemUpdate)hookOneFunc(g_fHitSystemUpdate,hHitSystemUpdate,(void**)&g_oHitSystemUpdate,&g_hHitSystemUpdate,"HitSystem.Update");
        g_enemyCount=0;g_fullDmgLC=0;
        jlog(@"FullScreen ON: Intersects+CheckHit+HitSysUpdate(Z) enabled");
    }else{jlog(@"FullScreen OFF");}
    refreshBtns();
}
-(void)sliderChanged:(UISlider*)s{
    g_damageLimit=(int)s.value;
    g_sliderLabel.text=[NSString stringWithFormat:@"\xe4\xbc\xa4\xe5\xae\xb3\xe4\xb8\x8a\xe9\x99\x90: %d",g_damageLimit];
}
-(void)skinSliderChanged:(UISlider*)s{
    g_skinId=(int)s.value;
    g_skinLabel.text=[NSString stringWithFormat:@"\xe7\x9a\xae\xe8\x82\xa4" "ID: %d",g_skinId];
}
-(void)weaponSliderChanged:(UISlider*)s{
    g_weaponId=(int)s.value;
    g_weaponLabel.text=[NSString stringWithFormat:@"\xe6\xad\xa6\xe5\x99\xa8" "ID: %d",g_weaponId];
}
// v55: 应用皮肤修改 - 不再每次调findIL2CPP(卡死根因)
-(void)onApplySkin{
    // v55修复: 移除findIL2CPP()调用,避免每次扫描156002方法导致卡死
    // Hook get_SkinId只安装一次
    if(!g_hGetSkinId && g_fGetSkinId) {
        hookOneFunc(g_fGetSkinId,hGetSkinId,(void**)&g_oGetSkinId,&g_hGetSkinId,"get_SkinId");
    }
    // 设置要应用的ID
    g_appliedSkinId=g_skinId;
    g_appliedWeaponId=g_weaponId;
    // 如果已找到Actor对象,直接写backing field
    if(g_playerActorObj){
        uint8_t *p=(uint8_t*)g_playerActorObj;
        int32_t curSkin=0,curWeapon=0;
        memcpy(&curSkin,p+0x110,4);
        memcpy(&curWeapon,p+0x114,4);
        jlog(@"ApplySkin: cur skin=%d weapon=%d -> new skin=%d weapon=%d",curSkin,curWeapon,g_skinId,g_weaponId);
        memcpy(p+0x110,&g_skinId,4);
        memcpy(p+0x114,&g_weaponId,4);
    } else {
        jlog(@"ApplySkin: Actor not found yet, will apply when get_SkinId is called");
    }
}
// v57: 读取皮肤ID列表 - 直接内存读取,不调用IL2CPP方法(不卡死)
-(void)onDumpSkinIds{
    if(!g_classGameEntryMain){jlog(@"DumpSkin: GameEntryMain not found, running findIL2CPP...");findIL2CPP();}
    if(g_skinIdsLoaded){
        jlog(@"DumpSkin: already scanned, role=%d weapon=%d",g_roleSkinCount,g_weaponSkinCount);
        refreshBtns();
        return;
    }
    jlog(@"DumpSkin: starting memory scan...");
    scanSkinIds();
    refreshBtns();
}
@end

// v53: Resize handle放在window上, 不被任何子视图遮挡
@interface JYJHResizeHandle : UIView { CGPoint _ts; }
@end
@implementation JYJHResizeHandle
-(instancetype)init{
    self=[super initWithFrame:CGRectMake(0,0,36,36)];
    if(self){
    self.backgroundColor=[UIColor clearColor];
    self.layer.zPosition=9999; // 确保在最顶层
    // 画一个圆角三角形
    UIView *t=[[UIView alloc]initWithFrame:CGRectMake(0,0,36,36)];
    t.backgroundColor=[UIColor colorWithRed:0.3 green:0.3 blue:0.4 alpha:0.85];
    t.layer.cornerRadius=6;[self addSubview:t];
    UILabel *l=[[UILabel alloc]initWithFrame:CGRectMake(0,0,36,36)];
    l.text=@"\xe2\x87\x98";l.textColor=[UIColor whiteColor];l.font=[UIFont systemFontOfSize:18];l.textAlignment=NSTextAlignmentCenter;[self addSubview:l];
    }return self;
}
-(BOOL)pointInside:(CGPoint)p withEvent:(UIEvent*)e{return CGRectContainsPoint(CGRectInset(self.bounds,-6,-6),p);}
-(void)touchesBegan:(NSSet*)t withEvent:(UIEvent*)e{_ts=[[t anyObject]locationInView:g_panel.superview];}
-(void)touchesMoved:(NSSet*)t withEvent:(UIEvent*)e{
    CGPoint c=[[t anyObject]locationInView:g_panel.superview];
    CGFloat nw=MAX(200,c.x-g_panel.frame.origin.x);
    CGFloat nh=MAX(300,c.y-g_panel.frame.origin.y);
    g_panelW=nw;g_panelH=nh;
    g_panel.frame=CGRectMake(g_panel.frame.origin.x,g_panel.frame.origin.y,nw,nh);
    // 同步更新ScrollView的frame
    if(g_scrollView){
        g_scrollView.frame=CGRectMake(0,32,nw,nh-32);
        CGFloat contentH=g_scrollView.contentSize.height;
        g_scrollView.contentSize=CGSizeMake(nw,contentH);
    }
    // 更新resize handle位置(在window上)
    if(g_resizeHandle) g_resizeHandle.frame=CGRectMake(g_panel.frame.origin.x+nw-36,g_panel.frame.origin.y+nh-36,36,36);
    if(g_resizeHandleTop) g_resizeHandleTop.frame=CGRectMake(g_panel.frame.origin.x+nw-36,g_panel.frame.origin.y,36,36);
}
@end

// v48: 标题栏拖动手势
@interface JYJHTitleDragView : UIView { CGPoint _ts; }
@end
@implementation JYJHTitleDragView
-(void)touchesBegan:(NSSet*)t withEvent:(UIEvent*)e{_ts=[[t anyObject]locationInView:g_panel.superview];}
-(void)touchesMoved:(NSSet*)t withEvent:(UIEvent*)e{
    CGPoint c=[[t anyObject]locationInView:g_panel.superview];
    CGFloat dx=c.x-_ts.x, dy=c.y-_ts.y;
    CGRect f=g_panel.frame;
    CGRect sc=[UIScreen mainScreen].bounds;
    // v52: 面板可自由拖到任意位置,只限制不超出屏幕
    f.origin.x=MAX(-f.size.width+40,MIN(sc.size.width-40,f.origin.x+dx));
    f.origin.y=MAX(-20,MIN(sc.size.height-60,f.origin.y+dy));
    g_panel.frame=f;
    // v53: 更新resize handle位置(在window上, 跟随面板)
    if(g_resizeHandle) g_resizeHandle.frame=CGRectMake(f.origin.x+g_panelW-36,f.origin.y+g_panelH-36,36,36);
    if(g_resizeHandleTop) g_resizeHandleTop.frame=CGRectMake(f.origin.x+g_panelW-36,f.origin.y,36,36);
    _ts=c;
}
@end

// Floating ball
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
    // 大面板 - 屏幕居中, v52: 去掉clipsToBounds让resize把手不被裁剪
    UIView *outer=[[UIView alloc]initWithFrame:CGRectMake(0,0,g_panelW,g_panelH)];outer.backgroundColor=IMGUI_BG;outer.layer.cornerRadius=10;outer.layer.borderWidth=1;outer.layer.borderColor=IMGUI_BORDER.CGColor;outer.hidden=YES;g_panel=outer;[win addSubview:outer];
    layoutPanelCenter();
    // Title bar (固定在顶部, 可拖动)
    JYJHTitleDragView *tb=[[JYJHTitleDragView alloc]initWithFrame:CGRectMake(0,0,g_panelW,32)];tb.backgroundColor=IMGUI_TITLE_BG;[outer addSubview:tb];g_titleBar=tb;
    UILabel *tl=[[UILabel alloc]initWithFrame:CGRectMake(10,6,g_panelW-20,20)];tl.text=@"\xe5\x89\x91\xe5\xbd\xb1\xe6\xb1\x9f\xe6\xb9\x96 v57.0";tl.textColor=IMGUI_ACCENT;tl.font=[UIFont boldSystemFontOfSize:15];tl.textAlignment=NSTextAlignmentCenter;[tb addSubview:tl];
    // UIScrollView (滚动内容区)
    UIScrollView *sv=[[UIScrollView alloc]initWithFrame:CGRectMake(0,32,g_panelW,g_panelH-32)];
    sv.showsVerticalScrollIndicator=YES;
    sv.delaysContentTouches=NO;
    sv.canCancelContentTouches=YES;
    sv.scrollEnabled=YES;
    sv.userInteractionEnabled=YES;
    [outer addSubview:sv];
    g_scrollView=sv;
    CGFloat bx=12,bw=g_panelW-24,bh=24,by0=4,bdy=28;
    CGFloat contentH=by0+bdy*4+60+188; // v56: 增加高度以容纳scan button
    sv.contentSize=CGSizeMake(g_panelW,contentH);
    // Buttons
    g_btnIgnoreUnlock=mkBtn(CGRectMake(bx,by0,bw,bh),@selector(onIgnoreUnlock));[sv addSubview:g_btnIgnoreUnlock];
    g_btnExSkillNoCD=mkBtn(CGRectMake(bx,by0+bdy,bw,bh),@selector(onExSkillNoCD));[sv addSubview:g_btnExSkillNoCD];
    g_btnGodMode=mkBtn(CGRectMake(bx,by0+bdy*2,bw,bh),@selector(onGodMode));[sv addSubview:g_btnGodMode];
    g_btnFullScreen=mkBtn(CGRectMake(bx,by0+bdy*3,bw,bh),@selector(onFullScreen));[sv addSubview:g_btnFullScreen];
    // Sep1
    CGFloat s1Y=by0+bdy*4;UIView *s1=[[UIView alloc]initWithFrame:CGRectMake(bx,s1Y,bw,1)];s1.backgroundColor=IMGUI_BORDER;[sv addSubview:s1];
    // Damage slider
    CGFloat sy=s1Y+8;
    g_sliderLabel=[[UILabel alloc]initWithFrame:CGRectMake(bx,sy,bw,18)];g_sliderLabel.text=[NSString stringWithFormat:@"\xe4\xbc\xa4\xe5\xae\xb3\xe4\xb8\x8a\xe9\x99\x90: %d",g_damageLimit];g_sliderLabel.textColor=IMGUI_DIMTEXT;g_sliderLabel.font=[UIFont systemFontOfSize:12];[sv addSubview:g_sliderLabel];
    g_slider=[[UISlider alloc]initWithFrame:CGRectMake(bx,sy+20,bw,28)];g_slider.minimumValue=1;g_slider.maximumValue=5000;g_slider.value=g_damageLimit;[g_slider addTarget:[JYJHActionHandler shared] action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];[sv addSubview:g_slider];
    // Sep2
    CGFloat s2Y=sy+52;UIView *s2=[[UIView alloc]initWithFrame:CGRectMake(bx,s2Y,bw,1)];s2.backgroundColor=IMGUI_BORDER;[sv addSubview:s2];
    // Skin section
    CGFloat ssy=s2Y+6;
    UILabel *secT=[[UILabel alloc]initWithFrame:CGRectMake(bx,ssy,bw,18)];secT.text=@"\xe7\x9a\xae\xe8\x82\xa4/\xe6\xad\xa6\xe5\x99\xa8" "(\xe6\x88\x98\xe6\x96\x97\xe4\xb8\xad\xe5\x86\x99" "Actor" "\xe5\xad\x97\xe6\xae\xb5)";secT.textColor=IMGUI_ACCENT;secT.font=[UIFont boldSystemFontOfSize:11];[sv addSubview:secT];
    // Skin slider
    g_skinLabel=[[UILabel alloc]initWithFrame:CGRectMake(bx,ssy+20,bw,18)];g_skinLabel.text=[NSString stringWithFormat:@"\xe7\x9a\xae\xe8\x82\xa4" "ID: %d",g_skinId];g_skinLabel.textColor=IMGUI_DIMTEXT;g_skinLabel.font=[UIFont systemFontOfSize:12];[sv addSubview:g_skinLabel];
    g_skinSlider=[[UISlider alloc]initWithFrame:CGRectMake(bx,ssy+38,bw,28)];g_skinSlider.minimumValue=0;g_skinSlider.maximumValue=2000;g_skinSlider.value=g_skinId;[g_skinSlider addTarget:[JYJHActionHandler shared] action:@selector(skinSliderChanged:) forControlEvents:UIControlEventValueChanged];[sv addSubview:g_skinSlider];
    // Weapon slider
    g_weaponLabel=[[UILabel alloc]initWithFrame:CGRectMake(bx,ssy+68,bw,18)];g_weaponLabel.text=[NSString stringWithFormat:@"\xe6\xad\xa6\xe5\x99\xa8" "ID: %d",g_weaponId];g_weaponLabel.textColor=IMGUI_DIMTEXT;g_weaponLabel.font=[UIFont systemFontOfSize:12];[sv addSubview:g_weaponLabel];
    g_weaponSlider=[[UISlider alloc]initWithFrame:CGRectMake(bx,ssy+86,bw,28)];g_weaponSlider.minimumValue=0;g_weaponSlider.maximumValue=2000;g_weaponSlider.value=g_weaponId;[g_weaponSlider addTarget:[JYJHActionHandler shared] action:@selector(weaponSliderChanged:) forControlEvents:UIControlEventValueChanged];[sv addSubview:g_weaponSlider];
    // v54: Apply skin button
    g_btnApplySkin=mkBtn(CGRectMake(bx,ssy+118,bw,bh),@selector(onApplySkin));[sv addSubview:g_btnApplySkin];
    // v56: 扫描皮肤ID按钮
    g_btnScanSkin=mkBtn(CGRectMake(bx,ssy+146,bw,bh),@selector(onDumpSkinIds));[sv addSubview:g_btnScanSkin];
    // v49: 移除"查询皮肤ID列表"按钮(Tables无static实例,功能无用)
    // v53: Resize handle放在window上(不被任何子视图遮挡)
    g_resizeHandle=[[JYJHResizeHandle alloc]init];
    CGRect panelFrame=g_panel.frame;
    g_resizeHandle.frame=CGRectMake(panelFrame.origin.x+g_panelW-36,panelFrame.origin.y+g_panelH-36,36,36);
    g_resizeHandle.hidden=YES; // 面板关闭时隐藏
    [win addSubview:g_resizeHandle];
    // 右上角resize handle
    g_resizeHandleTop=[[JYJHResizeHandle alloc]init];
    g_resizeHandleTop.frame=CGRectMake(panelFrame.origin.x+g_panelW-36,panelFrame.origin.y,36,36);
    g_resizeHandleTop.hidden=YES;
    [win addSubview:g_resizeHandleTop];
    refreshBtns();
}

__attribute__((constructor))
static void initialize(void){
    static BOOL loaded=NO; if(loaded)return; loaded=YES;
    jlog(@"========== JYJH v57.0 ==========");
    jlog(@"iOS %@",[[UIDevice currentDevice] systemVersion]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(5.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        jlog(@"5s delay done"); applyAllHooks();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{setupUI();});
    });
}