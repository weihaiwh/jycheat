/**
 * v53.0 - Hook HitSystem.Update扩大HitBoundZ+修复缩放handle
 * v52问题:
 *   1. 全屏秒杀只有水平线敌人被打到 - Z轴(FootY差值vsHitBoundZ)判断阻止了不同深度的敌人
 *   2. 缩放handle仍不可点击 - ScrollView覆盖了整个内容区,handle被遮挡
 * v53方案:
 *   1. Hook HitSystem.Update(0x30ce950), 在调用原始前遍历Frame中所有HitBox组件,
 *      临时将HitBoundZ(+0x50)设为超大值(FP RawValue=0x7FFFFFFFFFFFFFFF),
 *      调用原始后恢复原始值. 这样Z轴判定也通过, 走正常帧同步路径.
 *   2. 缩放handle改成放在window上(而非outer内),不被任何子视图遮挡.
 *      右上角和右下角各一个handle, 位置跟随面板.
 *   3. 禁用DecreaseHP扩散(之前已证明破坏帧同步)
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

// v53: HitBox struct字段偏移 (v1.10.1 dump)
// Camp:+0x1c, IsActive:+0x2c, attacker:+0x38, FootY:+0x48, HitBoundZ:+0x50, bound:+0x58
#define HITBOX_FOOTY_OFF 0x48
#define HITBOX_HITBOUNDZ_OFF 0x50
#define HITBOX_BOUND_OFF 0x58
#define HITBOX_ISACTIVE_OFF 0x2c
// ComponentDataBuffer字段偏移
#define CDB_COUNT_OFF 0x14
#define CDB_STRIDE_OFF 0x1c
#define CDB_BLOCKSLIST_OFF 0x28
#define CDB_BLOCKSLISTCOUNT_OFF 0x34
// Block字段偏移
#define BLOCK_PACKEDDATA_OFF 0x18
// FrameBase字段偏移
#define FB_COMPONENTBUFFERS_OFF 0x58
#define FB_COMPONENTBUFFERSLENGTH_OFF 0x60
// FP RawValue超大值 (FP使用定点数, RawValue=Int64)
#define FP_HUGE_RAW ((int64_t)0x7FFFFFFFFFFFFFFF)
// 保存HitBoundZ原始值的数组
#define MAX_HITBOX_SAVE 64
static int64_t g_savedHitBoundZ[MAX_HITBOX_SAVE];
static int g_savedHitBoundCount=0;

static void *g_playerCF=NULL, *g_playerEntity=NULL; static BOOL g_playerCFLearned=NO;
#define MAX_ENEMIES 64
static void *g_enemyCFs[MAX_ENEMIES], *g_enemyEntities[MAX_ENEMIES]; static int g_enemyCount=0;

#define MAX_SKIN_IDS 256
static int32_t g_roleSkinIds[MAX_SKIN_IDS], g_weaponSkinIds[MAX_SKIN_IDS];
static int g_roleSkinCount=0, g_weaponSkinCount=0;
static BOOL g_skinIdsLoaded=NO;

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

// v53: HitSystem.Update Hook - 遍历所有HitBox, 临时扩大HitBoundZ
static int g_hitSysLC=0;
static void hHitSystemUpdate(void *self, void *framePtr) {
    if(!g_fullScreen || !framePtr) {
        if(g_oHitSystemUpdate) g_oHitSystemUpdate(self, framePtr);
        return;
    }
    // 遍历Frame中的ComponentDataBuffer, 找HitBox组件并扩大HitBoundZ
    g_savedHitBoundCount=0;
    uint8_t *fb=(uint8_t*)framePtr;
    void *cBufArr=NULL; int cBufLen=0;
    memcpy(&cBufArr, fb+FB_COMPONENTBUFFERS_OFF, sizeof(void*));
    memcpy(&cBufLen, fb+FB_COMPONENTBUFFERSLENGTH_OFF, sizeof(int));
    if(!cBufArr || cBufLen<=0) {
        if(g_oHitSystemUpdate) g_oHitSystemUpdate(self, framePtr);
        return;
    }
    // 遍历所有ComponentDataBuffer
    for(int bi=0; bi<cBufLen; bi++) {
        uint8_t *cdb=(uint8_t*)cBufArr + bi * sizeof(void*);
        void *cdbPtr=NULL;
        memcpy(&cdbPtr, cdb, sizeof(void*));
        if(!cdbPtr) continue;
        // 读取stride和count
        int32_t stride=0, count=0;
        memcpy(&stride, (uint8_t*)cdbPtr+CDB_STRIDE_OFF, 4);
        memcpy(&count, (uint8_t*)cdbPtr+CDB_COUNT_OFF, 4);
        if(count<=0 || stride<=0 || stride>4096) continue;
        // HitBox struct大小应该是约0x80左右, 用stride粗略匹配
        // HitBox的IsActive(+0x2c)是QBoolean(Int32), 非零=active
        // 读取blocksList
        void *blocksList=NULL; int32_t blocksListCount=0;
        memcpy(&blocksList, (uint8_t*)cdbPtr+CDB_BLOCKSLIST_OFF, sizeof(void*));
        memcpy(&blocksListCount, (uint8_t*)cdbPtr+CDB_BLOCKSLISTCOUNT_OFF, 4);
        if(!blocksList || blocksListCount<=0) continue;
        // 遍历blocks
        int savedIdx=0;
        for(int blk=0; blk<blocksListCount && savedIdx<MAX_HITBOX_SAVE; blk++) {
            uint8_t *block=(uint8_t*)blocksList + blk * sizeof(void*);
            void *blockPtr=NULL;
            memcpy(&blockPtr, block, sizeof(void*));
            if(!blockPtr) continue;
            uint8_t *packedData=NULL;
            memcpy(&packedData, (uint8_t*)blockPtr+BLOCK_PACKEDDATA_OFF, sizeof(void*));
            if(!packedData) continue;
            // 遍历block中的组件数据
            // 每个block的容量=_blockCapacity, 但实际数量需要通过count推算
            int remaining=count-savedIdx;
            for(int ci=0; ci<remaining && savedIdx<MAX_HITBOX_SAVE; ci++, savedIdx++) {
                uint8_t *hitboxData=packedData + ci * stride;
                // 检查IsActive(+0x2c) - QBoolean, 非零表示活跃
                int32_t isActive=0;
                memcpy(&isActive, hitboxData+HITBOX_ISACTIVE_OFF, 4);
                if(isActive==0) continue;
                // 检查HitBoundZ(+0x50)是否为合理值(非零且不太大)
                int64_t hitBoundZ=0;
                memcpy(&hitBoundZ, hitboxData+HITBOX_HITBOUNDZ_OFF, 8);
                if(hitBoundZ==0) continue; // HitBoundZ=0的不需要修改
                // 保存原始HitBoundZ
                if(g_savedHitBoundCount<MAX_HITBOX_SAVE) {
                    g_savedHitBoundZ[g_savedHitBoundCount]=hitBoundZ;
                    // 设为超大值
                    int64_t huge=FP_HUGE_RAW;
                    memcpy(hitboxData+HITBOX_HITBOUNDZ_OFF, &huge, 8);
                    g_savedHitBoundCount++;
                }
            }
        }
    }
    // 调用原始Update
    if(g_oHitSystemUpdate) g_oHitSystemUpdate(self, framePtr);
    // 恢复HitBoundZ
    // 需要重新遍历来恢复(因为PackedData指针可能不变)
    {
        int restoreIdx=0;
        for(int bi=0; bi<cBufLen && restoreIdx<g_savedHitBoundCount; bi++) {
            uint8_t *cdb=(uint8_t*)cBufArr + bi * sizeof(void*);
            void *cdbPtr=NULL;
            memcpy(&cdbPtr, cdb, sizeof(void*));
            if(!cdbPtr) continue;
            int32_t stride=0, count=0;
            memcpy(&stride, (uint8_t*)cdbPtr+CDB_STRIDE_OFF, 4);
            memcpy(&count, (uint8_t*)cdbPtr+CDB_COUNT_OFF, 4);
            if(count<=0 || stride<=0 || stride>4096) continue;
            void *blocksList=NULL; int32_t blocksListCount=0;
            memcpy(&blocksList, (uint8_t*)cdbPtr+CDB_BLOCKSLIST_OFF, sizeof(void*));
            memcpy(&blocksListCount, (uint8_t*)cdbPtr+CDB_BLOCKSLISTCOUNT_OFF, 4);
            if(!blocksList || blocksListCount<=0) continue;
            int savedIdx2=0;
            for(int blk=0; blk<blocksListCount && restoreIdx<g_savedHitBoundCount; blk++) {
                uint8_t *block=(uint8_t*)blocksList + blk * sizeof(void*);
                void *blockPtr=NULL;
                memcpy(&blockPtr, block, sizeof(void*));
                if(!blockPtr) continue;
                uint8_t *packedData=NULL;
                memcpy(&packedData, (uint8_t*)blockPtr+BLOCK_PACKEDDATA_OFF, sizeof(void*));
                if(!packedData) continue;
                int remaining=count-savedIdx2;
                for(int ci=0; ci<remaining && restoreIdx<g_savedHitBoundCount; ci++, savedIdx2++) {
                    uint8_t *hitboxData=packedData + ci * stride;
                    int32_t isActive=0;
                    memcpy(&isActive, hitboxData+HITBOX_ISACTIVE_OFF, 4);
                    if(isActive==0) continue;
                    int64_t curZ=0;
                    memcpy(&curZ, hitboxData+HITBOX_HITBOUNDZ_OFF, 8);
                    if(curZ!=FP_HUGE_RAW) continue; // 只恢复我们改过的
                    memcpy(hitboxData+HITBOX_HITBOUNDZ_OFF, &g_savedHitBoundZ[restoreIdx], 8);
                    restoreIdx++;
                }
            }
        }
    }
    if(g_hitSysLC<10){g_hitSysLC++;jlog(@"HitSysUpdate: saved=%d",g_savedHitBoundCount);}
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
    jlog(@"=== v53.0 IL2CPP Search ===");
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
                // v45: cfg.Tables是普通类(无static s_instance)，需找运行时实例
                // dump显示所有字段都是instance(backing fields)，不是static
                // 方案: 通过IL2CPP GC handle或搜索已分配的对象找Tables实例
                jlog(@"Tables: all fields are instance (no static singleton), need runtime search");
                // 已知: TbRoleSkin offset=560(0x230), TbWeaponSkin offset=584(0x248)
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
            }
        }
    }
    jlog(@"Scanned %d methods, found %d targets, origDecreaseHP=%p",totalMethods,found,g_origDecreaseHP);
    g_skinIdsLoaded=YES;
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
static UIButton *g_btnIgnoreUnlock=nil,*g_btnExSkillNoCD=nil,*g_btnGodMode=nil,*g_btnFullScreen=nil,*g_btnDumpSkin=nil;
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
-(void)onIgnoreUnlock;-(void)onExSkillNoCD;-(void)onGodMode;-(void)onFullScreen;
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
-(void)onDumpSkinIds{
    findIL2CPP();
    jlog(@"DumpSkin: role=%d weapon=%d",g_roleSkinCount,g_weaponSkinCount);
    if(g_roleSkinCount==0&&g_weaponSkinCount==0)jlog(@"No skin IDs - Tables has no static singleton, need runtime instance search");
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
    UILabel *tl=[[UILabel alloc]initWithFrame:CGRectMake(10,6,g_panelW-20,20)];tl.text=@"\xe5\x89\x91\xe5\xbd\xb1\xe6\xb1\x9f\xe6\xb9\x96 v53.0";tl.textColor=IMGUI_ACCENT;tl.font=[UIFont boldSystemFontOfSize:15];tl.textAlignment=NSTextAlignmentCenter;[tb addSubview:tl];
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
    CGFloat contentH=by0+bdy*4+60+120;
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
    g_skinSlider=[[UISlider alloc]initWithFrame:CGRectMake(bx,ssy+38,bw,28)];g_skinSlider.minimumValue=0;g_skinSlider.maximumValue=200;g_skinSlider.value=g_skinId;[g_skinSlider addTarget:[JYJHActionHandler shared] action:@selector(skinSliderChanged:) forControlEvents:UIControlEventValueChanged];[sv addSubview:g_skinSlider];
    // Weapon slider
    g_weaponLabel=[[UILabel alloc]initWithFrame:CGRectMake(bx,ssy+68,bw,18)];g_weaponLabel.text=[NSString stringWithFormat:@"\xe6\xad\xa6\xe5\x99\xa8" "ID: %d",g_weaponId];g_weaponLabel.textColor=IMGUI_DIMTEXT;g_weaponLabel.font=[UIFont systemFontOfSize:12];[sv addSubview:g_weaponLabel];
    g_weaponSlider=[[UISlider alloc]initWithFrame:CGRectMake(bx,ssy+86,bw,28)];g_weaponSlider.minimumValue=0;g_weaponSlider.maximumValue=200;g_weaponSlider.value=g_weaponId;[g_weaponSlider addTarget:[JYJHActionHandler shared] action:@selector(weaponSliderChanged:) forControlEvents:UIControlEventValueChanged];[sv addSubview:g_weaponSlider];
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
    jlog(@"========== JYJH v53.0 ==========");
    jlog(@"iOS %@",[[UIDevice currentDevice] systemVersion]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(5.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        jlog(@"5s delay done"); applyAllHooks();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{setupUI();});
    });
}