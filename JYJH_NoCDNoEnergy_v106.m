/**
 * v106 - SSO bypass: il2cpp_class_get_method_from_name
 * v105问题:
 *   ASLR slide计算错误! Singleton<T>.get_Instance在Main.Runtime.dll,
 *   而DoHandShakeCheck在HotfixBusiness.dll, 两个DLL基址不同!
 *   用HotfixBusiness的slide算Main.Runtime的地址 → 指向错误地址 → crash
 * v106方案:
 *   1. 用il2cpp_class_get_method_from_name(klass,"get_Instance",0)获取MethodInfo*
 *   2. 用il2cpp_compile_method(methodInfo)获取native函数指针
 *   3. 直接调用get_Instance获取LoginModel单例
 *   4. 备选: Nested类instance字段扫描
 *   5. 保留DoHandShakeCheck hook + 定时内存修补
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
static int g_damageLimit=100, g_skinId=0, g_weaponId=0;
static float g_speedMul=1.0f;
static BOOL g_bypassSSO=NO; // v102: SSO登录检测跳过

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

static void *g_fUnlock=NULL; static BoolFunc3 g_oUnlock=NULL; static BOOL g_hUnlock=NO;
static void *g_fLimitDmg=NULL; static IntFunc1 g_oLimitDmg=NULL; static BOOL g_hLimitDmg=NO;
static void *g_fIsReady=NULL; static BoolFunc4 g_oIsReady=NULL; static BOOL g_hIsReady=NO;
static void *g_fAttackCanUse=NULL; static BoolFunc4 g_oAttackCanUse=NULL; static BOOL g_hAttackCanUse=NO;
static void *g_fCanBeAttack=NULL; static CanBeAttackFunc g_oCanBeAttack=NULL; static BOOL g_hCanBeAttack=NO;
static void *g_fDamage=NULL; static DamageFunc g_oDamage=NULL; static BOOL g_hDamage=NO;
static void *g_fIntersects=NULL; static IntersectsFunc g_oIntersects=NULL; static BOOL g_hIntersects=NO;
static void *g_fCheckHit=NULL; static CheckHitFunc g_oCheckHit=NULL; static BOOL g_hCheckHit=NO;
static void *g_fUseSkill=NULL; static UseSkillFunc g_oUseSkill=NULL; static BOOL g_hUseSkill=NO;
typedef void (*HandleSkillRangeFunc)(void*,void*,int32_t,void*);
static void *g_fHandleSkillRange=NULL; static HandleSkillRangeFunc g_oHandleSkillRange=NULL; static BOOL g_hHandleSkillRange=NO;
static void *g_fUpdateSkillCD=NULL; static UpdateSkillCDFunc g_oUpdateSkillCD=NULL; static BOOL g_hUpdateSkillCD=NO;
typedef void (*HitSystemUpdateFunc)(void*,void*);
static void *g_fHitSystemUpdate=NULL; static HitSystemUpdateFunc g_oHitSystemUpdate=NULL; static BOOL g_hHitSystemUpdate=NO;
static DecreaseHPFunc g_origDecreaseHP = NULL;
static void *g_classActor=NULL;

// v106: SSO登录检测跳过 — 直接内存修改方案
// 问题: get_code/get_banTime被IL2CPP泛型共享, MSHookFunction hook会拦截所有Int32/Int64 getter
// 方案1: hook DoHandShakeCheck(int32 code) — 唯一地址, 让code强制为200
// 方案2: 直接修改LoginModel.CurSSOResponData内存 (code@0x10, banTime@0x38)
// LoginModel: Singleton<LoginModel>, CurSSOResponData @ offset 0xf0
// SSOResponData: code @ 0x10 (Int32), token @ 0x18 (String), banTime @ 0x38 (Int64)
static void *g_fDoHandShakeCheck=NULL; // LoginCtrl.DoHandShakeCheck(int32 code) — 唯一地址
typedef BOOL (*DoHandShakeCheckFunc)(void*,int32_t); // (self, code)
static DoHandShakeCheckFunc g_oDoHandShakeCheck=NULL; static BOOL g_hDoHandShakeCheck=NO;
static void *g_classLoginModel=NULL; // LoginModel类指针
static void *g_classLoginCtrl=NULL;  // LoginCtrl类指针
// v106: 保留g_fGetCode/g_fGetBanTime用于搜索, 但不再MSHookFunction它们
static void *g_fGetCode=NULL;   // 仅用于日志确认找到
static void *g_fGetBanTime=NULL; // 仅用于日志确认找到

// 皮肤 (v102: 禁用, 保留变量但不hook)
static int32_t g_appliedSkinId=0, g_appliedWeaponId=0;
static void *g_fGetSkinId=NULL;
typedef int32_t (*GetSkinIdFunc)(void*);
static GetSkinIdFunc g_oGetSkinId=NULL; static BOOL g_hGetSkinId=NO;
static void *g_playerActorObj=NULL;
static int g_skinIdHookLC=0;
typedef void (*InitWithSkinIdFunc)(void*,int32_t,int32_t);
static void *g_fInitWithSkinId=NULL;

// MoveStep
typedef void (*MoveStepFunc)(void*,void*,void*,void*,void*,void*,void*,void*);
static void *g_fMoveStep=NULL; static MoveStepFunc g_oMoveStep=NULL; static BOOL g_hMoveStep=NO;
static int g_moveLC=0;

static BOOL isPlayerCF(void *cf) { if(!cf)return NO; int32_t v=-1; memcpy(&v,(uint8_t*)cf+0x44,4); return v==0; }
static BOOL isDeadCF(void *cf) { if(!cf)return YES; int32_t v=-1; memcpy(&v,(uint8_t*)cf+0x48,4); return v!=0; }

// ===== v106: DoHandShakeCheck hook =====
// DoHandShakeCheck(int32 code) 是LoginCtrl检查SSO响应码的方法
// 地址0x2b7eb2c是唯一的(不被IL2CPP泛型共享)
// hook它: 当bypassSSO开启时, 强制code参数为200
static BOOL hDoHandShakeCheck(void *self, int32_t code) {
    if(g_bypassSSO && code != 200) {
        jlog(@"SSO: DoHandShakeCheck code=%d → forced to 200", code);
        if(g_oDoHandShakeCheck) return g_oDoHandShakeCheck(self, 200);
        return YES; // code=200应该返回YES(通过)
    }
    return g_oDoHandShakeCheck ? g_oDoHandShakeCheck(self, code) : YES;
}

// v106: 直接内存修改SSOResponData (备用方案, 声明在前, 定义在isValidPtr/getObjClassName之后)
static void patchSSOResponDataMemory(void);

static int32_t hGetSkinId(void *self) {
    if(self && !g_playerActorObj) {
        g_playerActorObj=self;
        int32_t skinId=0,weaponId=0;
        memcpy(&skinId,(uint8_t*)self+0x110,4);
        memcpy(&weaponId,(uint8_t*)self+0x114,4);
        jlog(@"FOUND player Actor=%p skin=%d weapon=%d",self,skinId,weaponId);
    }
    int32_t r=g_oGetSkinId?g_oGetSkinId(self):0;
    if(self==g_playerActorObj && g_appliedSkinId>0) {
        if(g_skinIdHookLC<10){g_skinIdHookLC++;jlog(@"get_SkinId: %d->%d",r,g_appliedSkinId);}
        return g_appliedSkinId;
    }
    return r;
}

static void hMoveStep(void *f,void *entity,void *cf,void *moveDir,void *msx,void *msy,void *dt,void *tf) {
    if(g_speedMul>1.0f && cf && isPlayerCF(cf)) {
        int64_t origSpeed=0;
        memcpy(&origSpeed,(uint8_t*)cf+0x80,8);
        int64_t newSpeed = (int64_t)((double)origSpeed * g_speedMul);
        memcpy((uint8_t*)cf+0x80,&newSpeed,8);
        int64_t origSprint=0;
        memcpy(&origSprint,(uint8_t*)cf+0x88,8);
        int64_t newSprint = (int64_t)((double)origSprint * g_speedMul);
        memcpy((uint8_t*)cf+0x88,&newSprint,8);
        if(moveDir) {
            int64_t dx=0,dy=0;
            memcpy(&dx,moveDir,8);
            memcpy(&dy,(uint8_t*)moveDir+8,8);
            int64_t ndx=(int64_t)((double)dx*g_speedMul);
            int64_t ndy=(int64_t)((double)dy*g_speedMul);
            memcpy(moveDir,&ndx,8);
            memcpy((uint8_t*)moveDir+8,&ndy,8);
            if(g_moveLC<10){g_moveLC++;jlog(@"MoveStep: ×%.1f",g_speedMul);}
        }
        if(g_oMoveStep) g_oMoveStep(f,entity,cf,moveDir,msx,msy,dt,tf);
        memcpy((uint8_t*)cf+0x80,&origSpeed,8);
        memcpy((uint8_t*)cf+0x88,&origSprint,8);
        return;
    }
    if(g_oMoveStep) g_oMoveStep(f,entity,cf,moveDir,msx,msy,dt,tf);
}

#define HITSYS_COLLBOUND_OFF 0x38
#define HITSYS_EXTENTS_X_OFF (HITSYS_COLLBOUND_OFF+0x10)
#define HITSYS_EXTENTS_Y_OFF (HITSYS_COLLBOUND_OFF+0x18)
static int64_t g_savedExtX=0, g_savedExtY=0;

static void *g_playerCF=NULL, *g_playerEntity=NULL; static BOOL g_playerCFLearned=NO;
#define MAX_ENEMIES 64
static void *g_enemyCFs[MAX_ENEMIES], *g_enemyEntities[MAX_ENEMIES]; static int g_enemyCount=0;

static void *g_classUnityGameEntry=NULL;
static void *g_classHotfixGameEntry=NULL;
static void *g_classConfigComponent=NULL;
static void *g_classHotfixConfigComponent=NULL;
#define MAX_GAME_ENTRIES 8
static void *g_allGameEntries[MAX_GAME_ENTRIES];
static const char *g_allGameEntryNS[MAX_GAME_ENTRIES];
static int g_gameEntryCount=0;
#define MAX_SKIN_IDS 256
static int32_t g_roleSkinIds[MAX_SKIN_IDS], g_weaponSkinIds[MAX_SKIN_IDS];
static int g_roleSkinCount=0, g_weaponSkinCount=0;
static BOOL g_skinIdsLoaded=NO;

static BOOL isValidPtr(void *p) {
    if(!p) return NO;
    uint64_t v=0; memcpy(&v,&p,8);
    return (v>=0x100000000ULL && v<=0x1FFFFFFFFFFFULL);
}

static void *getStaticData(void *klass) {
    if(!klass) return NULL;
    void *h=dlopen(NULL,RTLD_LAZY);
    if(!h) return NULL;
    typedef void* (*Fn)(void*);
    Fn func=(Fn)dlsym(h,"il2cpp_class_get_static_field_data");
    if(!func) return NULL;
    return func(klass);
}

static const char *getObjClassName(void *obj) {
    if(!obj) return NULL;
    void *klass=NULL; memcpy(&klass,(uint8_t*)obj,8);
    if(!klass) return NULL;
    void *h=dlopen(NULL,RTLD_LAZY); if(!h) return NULL;
    typedef const char* (*Fn)(void*);
    Fn func=(Fn)dlsym(h,"il2cpp_class_get_name");
    return func ? func(klass) : NULL;
}

static const char *getObjClassNamespace(void *obj) {
    if(!obj) return NULL;
    void *klass=NULL; memcpy(&klass,(uint8_t*)obj,8);
    if(!klass) return NULL;
    void *h=dlopen(NULL,RTLD_LAZY); if(!h) return NULL;
    typedef const char* (*Fn)(void*);
    Fn func=(Fn)dlsym(h,"il2cpp_class_get_namespace");
    return func ? func(klass) : NULL;
}

// v106: 直接内存修改SSOResponData (实现)
// v105问题: ASLR slide计算错误(不同DLL有不同基址)
// v106方案: 用il2cpp_class_get_method_from_name获取get_Instance的MethodInfo
//           然后il2cpp_compile_method获取native指针, 直接调用
static void patchSSOResponDataMemory(void) {
    if(!g_classLoginModel) {jlog(@"SSO: LoginModel class not found");return;}
    void *h=dlopen(NULL,RTLD_LAZY); if(!h) return;
    void *loginModelInstance=NULL;

    // 方案1: il2cpp_class_get_method_from_name + il2cpp_compile_method
    {
        typedef void* (*GCMFn)(void*,const char*,int); 
        GCMFn gcm=(GCMFn)dlsym(h,"il2cpp_class_get_method_from_name");
        typedef void* (*CMFn)(void*);
        CMFn cm=(CMFn)dlsym(h,"il2cpp_compile_method");

        if(gcm && cm) {
            // LoginModel.get_Instance() — 0参数静态方法
            void *methodInfo=gcm(g_classLoginModel,"get_Instance",0);
            jlog(@"SSO: get_method_from_name(LoginModel,get_Instance,0)=%p",methodInfo);
            if(methodInfo) {
                void *nativeFunc=cm(methodInfo);
                jlog(@"SSO: compile_method=%p",nativeFunc);
                if(nativeFunc) {
                    // 尝试多种调用方式
                    typedef void* (*GIFn0)(void);
                    typedef void* (*GIFn1)(void*);
                    loginModelInstance=((GIFn0)nativeFunc)();
                    jlog(@"SSO: get_Instance()[0]=%p",loginModelInstance);
                    if(!isValidPtr(loginModelInstance)||!(getObjClassName(loginModelInstance))||(strcmp(getObjClassName(loginModelInstance),"LoginModel")!=0)) {
                        loginModelInstance=((GIFn1)nativeFunc)(NULL);
                        jlog(@"SSO: get_Instance(NULL)[1]=%p",loginModelInstance);
                    }
                    if(isValidPtr(loginModelInstance)) {
                        const char *cn=getObjClassName(loginModelInstance);
                        jlog(@"SSO: get_Instance class=%s",cn?cn:"null");
                        if(cn && strcmp(cn,"LoginModel")==0) {
                            jlog(@"SSO: Found LoginModel via get_Instance!");
                        } else {
                            loginModelInstance=NULL;
                        }
                    }
                }
            } else {
                // get_Instance可能在父类Singleton<T>中, 搜索父类
                jlog(@"SSO: get_Instance not in LoginModel, trying parent...");
                typedef void* (*GPFn)(void*);
                GPFn getParent=(GPFn)dlsym(h,"il2cpp_class_get_parent");
                if(getParent) {
                    void *parent=getParent(g_classLoginModel);
                    if(parent) {
                        const char *pn=NULL;
                        typedef const char* (*CNFn)(void*); CNFn cnf=(CNFn)dlsym(h,"il2cpp_class_get_name");
                        if(cnf) pn=cnf(parent);
                        jlog(@"SSO: LoginModel parent=%p name=%s",parent,pn?pn:"null");
                        void *parentMI=gcm(parent,"get_Instance",0);
                        if(parentMI) {
                            void *parentFunc=cm(parentMI);
                            jlog(@"SSO: parent get_Instance native=%p",parentFunc);
                            if(parentFunc) {
                                typedef void* (*GIFn1)(void*);
                                loginModelInstance=((GIFn1)parentFunc)(NULL);
                                jlog(@"SSO: parent get_Instance(NULL)=%p",loginModelInstance);
                                if(!isValidPtr(loginModelInstance)) {
                                    typedef void* (*GIFn0)(void);
                                    loginModelInstance=((GIFn0)parentFunc)();
                                    jlog(@"SSO: parent get_Instance()[0]=%p",loginModelInstance);
                                }
                                if(isValidPtr(loginModelInstance)) {
                                    const char *cn=getObjClassName(loginModelInstance);
                                    jlog(@"SSO: class=%s",cn?cn:"null");
                                    if(cn && strcmp(cn,"LoginModel")!=0) loginModelInstance=NULL;
                                }
                            }
                        } else {
                            jlog(@"SSO: parent has no get_Instance either");
                        }
                    }
                }
            }
        } else {
            jlog(@"SSO: il2cpp_class_get_method_from_name or compile_method not found");
        }
    }

    // 方案2: 遍历所有Nested类找instance字段
    if(!isValidPtr(loginModelInstance)) {
        jlog(@"SSO: Trying Nested class scan...");
        typedef size_t (*ACFn)(void*); ACFn ac=(ACFn)dlsym(h,"il2cpp_domain_get_assemblies_size");
        typedef void** (*GAFn)(void*); GAFn ga=(GAFn)dlsym(h,"il2cpp_domain_get_assemblies");
        typedef void* (*GIFn)(void*); GIFn gi=(GIFn)dlsym(h,"il2cpp_assembly_get_image");
        typedef size_t (*CCFn)(void*); CCFn cc=(CCFn)dlsym(h,"il2cpp_image_get_class_count");
        typedef void* (*GCIFn)(void*,size_t); GCIFn gci=(GCIFn)dlsym(h,"il2cpp_image_get_class");
        typedef const char* (*CNFn)(void*); CNFn cn=(CNFn)dlsym(h,"il2cpp_class_get_name");
        typedef void* (*GFdFn)(void*,void**); GFdFn gfd=(GFdFn)dlsym(h,"il2cpp_class_get_fields");
        typedef const char* (*GFNFn)(void*); GFNFn gfn=(GFNFn)dlsym(h,"il2cpp_field_get_name");
        typedef void (*FSGVFn)(void*,void*); FSGVFn fsgv=(FSGVFn)dlsym(h,"il2cpp_field_static_get_value");

        if(ga&&gi&&cc&&gci&&cn&&gfd&&gfn&&fsgv) {
            void *domain=dlsym(h,"il2cpp_domain_get")?((void*(*)())dlsym(h,"il2cpp_domain_get"))():NULL;
            if(domain) {
                size_t assemCount=ac?ac(domain):0;
                void **assemblies=ga(domain);
                for(size_t a=0;a<assemCount;a++) {
                    void *img=gi(assemblies[a]); if(!img)continue;
                    size_t classCount=cc(img);
                    for(size_t c=0;c<classCount;c++) {
                        void *klass=gci(img,c); if(!klass)continue;
                        const char *className=cn(klass);
                        if(className && strstr(className,"Nested")!=NULL) {
                            void *it=NULL,*fld=NULL;
                            while((fld=gfd(klass,&it))!=NULL) {
                                const char *fn=gfn(fld);
                                if(fn && strcmp(fn,"instance")==0) {
                                    void *val=NULL;
                                    fsgv(fld,&val);
                                    if(isValidPtr(val)) {
                                        const char *vCn=getObjClassName(val);
                                        jlog(@"SSO: %s.instance=%p class=%s",className,val,vCn?vCn:"null");
                                        if(vCn && strcmp(vCn,"LoginModel")==0) {
                                            loginModelInstance=val;
                                            jlog(@"SSO: Found LoginModel via Nested!");
                                            break;
                                        }
                                    }
                                }
                            }
                        }
                        if(isValidPtr(loginModelInstance)) break;
                    }
                    if(isValidPtr(loginModelInstance)) break;
                }
            }
        }
        if(!isValidPtr(loginModelInstance)) jlog(@"SSO: Nested scan failed");
    }

    // 方案3: 通过LoginCtrl.get_Instance -> mModel
    if(!isValidPtr(loginModelInstance) && g_classLoginCtrl) {
        jlog(@"SSO: Trying LoginCtrl...");
        typedef void* (*GCMFn)(void*,const char*,int);
        GCMFn gcm2=(GCMFn)dlsym(h,"il2cpp_class_get_method_from_name");
        typedef void* (*CMFn)(void*);
        CMFn cm2=(CMFn)dlsym(h,"il2cpp_compile_method");
        if(gcm2 && cm2) {
            void *lcMI=gcm2(g_classLoginCtrl,"get_Instance",0);
            if(lcMI) {
                void *lcFunc=cm2(lcMI);
                jlog(@"SSO: LoginCtrl.get_Instance native=%p",lcFunc);
                if(lcFunc) {
                    typedef void* (*GIFn1)(void*);
                    void *lcInst=((GIFn1)lcFunc)(NULL);
                    jlog(@"SSO: LoginCtrl.get_Instance(NULL)=%p",lcInst);
                    if(!isValidPtr(lcInst)) {
                        typedef void* (*GIFn0)(void);
                        lcInst=((GIFn0)lcFunc)();
                        jlog(@"SSO: LoginCtrl.get_Instance()[0]=%p",lcInst);
                    }
                    if(isValidPtr(lcInst)) {
                        const char *vCn=getObjClassName(lcInst);
                        jlog(@"SSO: LoginCtrl class=%s",vCn?vCn:"null");
                        if(vCn && strcmp(vCn,"LoginCtrl")==0) {
                            memcpy(&loginModelInstance,(uint8_t*)lcInst+0x10,8);
                            jlog(@"SSO: LoginCtrl.mModel=%p",loginModelInstance);
                        }
                    }
                }
            }
        }
    }

    if(!isValidPtr(loginModelInstance)) {
        jlog(@"SSO: LoginModel instance not found (all 3 methods failed)");
        return;
    }

    // 验证对象类名
    const char *lmCn=getObjClassName(loginModelInstance);
    jlog(@"SSO: LoginModel instance=%p class=%s",loginModelInstance,lmCn?lmCn:"null");

    // LoginModel.CurSSOResponData @ offset 0xf0
    void *ssoRspData=NULL;
    memcpy(&ssoRspData,(uint8_t*)loginModelInstance+0xf0,8);
    if(!isValidPtr(ssoRspData)) {
        jlog(@"SSO: CurSSOResponData=%p not set yet",ssoRspData);
        return;
    }

    const char *cn=getObjClassName(ssoRspData);
    jlog(@"SSO: CurSSOResponData=%p className=%s",ssoRspData,cn?cn:"null");

    int32_t origCode=0;
    memcpy(&origCode,(uint8_t*)ssoRspData+0x10,4);
    int64_t origBanTime=0;
    memcpy(&origBanTime,(uint8_t*)ssoRspData+0x38,8);
    jlog(@"SSO: Before patch: code=%d banTime=%lld",origCode,origBanTime);

    if(origCode!=200) {
        int32_t newCode=200;
        memcpy((uint8_t*)ssoRspData+0x10,&newCode,4);
        int64_t newBanTime=0;
        memcpy((uint8_t*)ssoRspData+0x38,&newBanTime,8);
        jlog(@"SSO: Patched! code=%d->200 banTime=%lld->0",origCode,origBanTime);
    } else {
        jlog(@"SSO: code already 200, no patch needed");
    }
}


static void *getConfigViaHotfixEntry(void) {
    if(!g_classHotfixGameEntry) return NULL;
    void *sd=getStaticData(g_classHotfixGameEntry);
    if(!isValidPtr(sd)) return NULL;
    void *config=NULL;
    memcpy(&config,(uint8_t*)sd+0xa8,8);
    if(isValidPtr(config)) return config;
    return NULL;
}

static void *getConfigViaComponentList(void) {
    if(!g_classUnityGameEntry) return NULL;
    void *sd=getStaticData(g_classUnityGameEntry);
    if(!isValidPtr(sd)) return NULL;
    void *listObj=NULL;
    memcpy(&listObj,(uint8_t*)sd+0x0,8);
    if(!isValidPtr(listObj)) return NULL;
    for(int off=0;off<128;off+=8){
        void *p=NULL; memcpy(&p,(uint8_t*)listObj+off,8);
        if(!isValidPtr(p)) continue;
        const char *cn=getObjClassName(p);
        if(!cn) continue;
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

static void scanSkinIds(void) {
    if(g_skinIdsLoaded) return;
    g_roleSkinCount=0; g_weaponSkinCount=0;
    void *cc=getConfigComponent();
    if(!isValidPtr(cc)){g_skinIdsLoaded=NO;return;}
    void *tables_l=NULL;
    memcpy(&tables_l,(uint8_t*)cc+0x28,8);
    if(!isValidPtr(tables_l)){g_skinIdsLoaded=NO;return;}
    void *tbRoleSkin=NULL;
    memcpy(&tbRoleSkin,(uint8_t*)tables_l+0x230,8);
    if(!isValidPtr(tbRoleSkin)){g_skinIdsLoaded=NO;return;}
    void *dataList=NULL;
    memcpy(&dataList,(uint8_t*)tbRoleSkin+0x18,8);
    if(!isValidPtr(dataList)){g_skinIdsLoaded=NO;return;}
    void *itemsArray=NULL; int32_t listSize=0;
    for(int itemsOff=0x10;itemsOff<=0x28;itemsOff+=8){
        void *testArr=NULL; int32_t testSize=0;
        memcpy(&testArr,(uint8_t*)dataList+itemsOff,8);
        int sizeOff=itemsOff+8;
        if(sizeOff+4<=96) memcpy(&testSize,(uint8_t*)dataList+sizeOff,4);
        if(isValidPtr(testArr)&&testSize>0&&testSize<10000){
            int32_t testArrLen=0;
            memcpy(&testArrLen,(uint8_t*)testArr+0x18,4);
            if(testArrLen>=testSize&&testArrLen<100000){itemsArray=testArr;listSize=testSize;break;}
            memcpy(&testArrLen,(uint8_t*)testArr+0x10,4);
            if(testArrLen>=testSize&&testArrLen<100000){itemsArray=testArr;listSize=testSize;break;}
        }
    }
    if(!itemsArray||listSize<=0||!isValidPtr(itemsArray)){g_skinIdsLoaded=NO;return;}
    int32_t arrayLen=0;
    memcpy(&arrayLen,(uint8_t*)itemsArray+0x18,4);
    if(arrayLen<=0||arrayLen>100000){memcpy(&arrayLen,(uint8_t*)itemsArray+0x10,4);}
    int maxScan=(listSize<MAX_SKIN_IDS)?listSize:MAX_SKIN_IDS;
    for(int i=0;i<maxScan&&i<arrayLen;i++){
        void *roleSkinPtr=NULL;
        memcpy(&roleSkinPtr,(uint8_t*)itemsArray+0x20+i*8,8);
        if(!roleSkinPtr)continue;
        int32_t skinId=0;
        memcpy(&skinId,(uint8_t*)roleSkinPtr+0x10,4);
        if(skinId>0) g_roleSkinIds[g_roleSkinCount++]=skinId;
    }
    g_skinIdsLoaded=YES;
    jlog(@"ScanSkinIds: found %d role skin IDs",g_roleSkinCount);

    void *tbWeaponSkin=NULL;
    memcpy(&tbWeaponSkin,(uint8_t*)tables_l+0x248,8);
    if(isValidPtr(tbWeaponSkin)){
        void *wDataList=NULL;
        memcpy(&wDataList,(uint8_t*)tbWeaponSkin+0x18,8);
        if(isValidPtr(wDataList)){
            void *wItemsArray=NULL; int32_t wListSize=0;
            for(int itemsOff=0x10;itemsOff<=0x28;itemsOff+=8){
                void *testArr=NULL; int32_t testSize=0;
                memcpy(&testArr,(uint8_t*)wDataList+itemsOff,8);
                int sizeOff=itemsOff+8;
                if(sizeOff+4<=96) memcpy(&testSize,(uint8_t*)wDataList+sizeOff,4);
                if(isValidPtr(testArr)&&testSize>0&&testSize<10000){
                    int32_t testArrLen=0;
                    memcpy(&testArrLen,(uint8_t*)testArr+0x18,4);
                    if(testArrLen>=testSize&&testArrLen<100000){wItemsArray=testArr;wListSize=testSize;break;}
                }
            }
            if(wItemsArray&&wListSize>0){
                int32_t wArrLen=0;
                memcpy(&wArrLen,(uint8_t*)wItemsArray+0x18,4);
                int wMax=(wListSize<MAX_SKIN_IDS)?wListSize:MAX_SKIN_IDS;
                for(int i=0;i<wMax&&i<wArrLen;i++){
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
}

static void trackEnemy(void *cf, void *ent) {
    if(!cf||!ent||isPlayerCF(cf))return;
    for(int i=0;i<g_enemyCount;i++) if(g_enemyCFs[i]==cf){g_enemyEntities[i]=ent;return;}
    if(g_enemyCount<MAX_ENEMIES){g_enemyCFs[g_enemyCount]=cf;g_enemyEntities[g_enemyCount]=ent;g_enemyCount++;}
}

// ===== Hooks =====
static int g_unlockLC=0;
static BOOL hUnlock(void *s,int a1,int a2){if(g_ignoreUnlock){return YES;}return g_oUnlock?g_oUnlock(s,a1,a2):YES;}
static int g_isReadyLC=0;
static BOOL hIsReady(void *f,int st,void *cf,void *st2){
    if(cf){if(isPlayerCF(cf)){if(!g_playerCFLearned){g_playerCF=cf;g_playerCFLearned=YES;}}else trackEnemy(cf,NULL);}
    if(g_skillReplace&&st>=14&&st<=19) return YES;
    if(g_exSkillNoCD&&st>=17) return YES;
    return g_oIsReady?g_oIsReady(f,st,cf,st2):YES;
}
static int g_attackLC=0;
static BOOL hAttackCanUse(void *f,int st,void *cf,void *st2){
    if(cf&&isPlayerCF(cf)&&!g_playerCFLearned){g_playerCF=cf;g_playerCFLearned=YES;}
    if(g_skillReplace&&st>=14&&st<=19) return YES;
    if(g_exSkillNoCD&&st>=17) return YES;
    return g_oAttackCanUse?g_oAttackCanUse(f,st,cf,st2):YES;
}
static int hLimitDmg(void *s){return g_damageLimit;}
static int g_canBeAtkLC=0;
static BOOL hCanBeAttack(void *cf){
    if(cf){if(isPlayerCF(cf)&&g_godMode) return NO;else if(!isPlayerCF(cf)) trackEnemy(cf,NULL);}
    return g_oCanBeAttack?g_oCanBeAttack(cf):YES;
}
static int g_dmgLC=0;
static int64_t hDamage(void *f,void *atkEnt,void *atkCF,void *tgtEnt,void *tgtCF,
    int32_t hitEid,int32_t hitSnd,BOOL isR,int32_t sBtn,int32_t sPart,void *hurtF,void *exS){
    BOOL tgtP=(tgtCF&&isPlayerCF(tgtCF)), atkP=(atkCF&&isPlayerCF(atkCF));
    if(atkP&&atkEnt)g_playerEntity=atkEnt;
    if(tgtCF&&!tgtP&&tgtEnt)trackEnemy(tgtCF,tgtEnt);
    if(g_godMode&&tgtP) return 0;
    if(!g_oDamage)return 0;
    return g_oDamage(f,atkEnt,atkCF,tgtEnt,tgtCF,hitEid,hitSnd,isR,sBtn,sPart,hurtF,exS);
}
static BOOL hIntersects(void *s,void *o){if(g_fullScreen)return YES;return g_oIntersects?g_oIntersects(s,o):NO;}
static int32_t hCheckHit(void *f,void *cb){if(g_fullScreen)return 1;return g_oCheckHit?g_oCheckHit(f,cb):0;}

static void hUseSkill(void *f,void *entity,void *cf,int skillStateType,BOOL isRight,void *states,void *state,void *playerInfo) {
    if(g_skillReplace && skillStateType>=14 && skillStateType<=18) {
        if(cf) { int32_t isAI=1; memcpy(&isAI,(uint8_t*)cf+0x44,4); if(isAI==0) {
            BOOL rep=NO;
            if(skillStateType==14&&g_replaceSkill1) rep=YES;
            if(skillStateType==15&&g_replaceSkill2) rep=YES;
            if(skillStateType==16&&g_replaceSkill3) rep=YES;
            if(skillStateType==17&&g_replaceSkill4) rep=YES;
            if(skillStateType==18&&g_replaceSkill5) rep=YES;
            if(rep) skillStateType=19;
        }}
    }
    if(g_oUseSkill) g_oUseSkill(f,entity,cf,skillStateType,isRight,states,state,playerInfo);
}

static void hHandleSkillRange(void *f,void *cf,int32_t skillButton,void *exSkill) {
    if(g_oHandleSkillRange) g_oHandleSkillRange(f,cf,skillButton,exSkill);
}

static void hUpdateSkillCD(void *f,void *er,void *cf,void *states) {
    if(g_skillReplace) return;
    if(g_oUpdateSkillCD) g_oUpdateSkillCD(f,er,cf,states);
}

static int g_hitSysLC=0;
static void hHitSystemUpdate(void *self, void *framePtr) {
    if(!self) { if(g_oHitSystemUpdate) g_oHitSystemUpdate(self, framePtr); return; }
    if(g_hitSysLC<3) { g_hitSysLC++; jlog(@"HitSys[%d]", g_hitSysLC); }
    if(!g_fullScreen) { if(g_oHitSystemUpdate) g_oHitSystemUpdate(self, framePtr); return; }
    uint8_t *p=(uint8_t*)self;
    memcpy(&g_savedExtX, p+HITSYS_EXTENTS_X_OFF, 8);
    memcpy(&g_savedExtY, p+HITSYS_EXTENTS_Y_OFF, 8);
    int64_t huge=0x7FFFFFFFFFFFFFFF;
    memcpy(p+HITSYS_EXTENTS_X_OFF, &huge, 8);
    memcpy(p+HITSYS_EXTENTS_Y_OFF, &huge, 8);
    if(g_oHitSystemUpdate) g_oHitSystemUpdate(self, framePtr);
    memcpy(p+HITSYS_EXTENTS_X_OFF, &g_savedExtX, 8);
    memcpy(p+HITSYS_EXTENTS_Y_OFF, &g_savedExtY, 8);
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

static BOOL g_il2cppDone=NO;

static void findIL2CPP(void) {
    if(g_il2cppDone) return;
    jlog(@"=== v83 IL2CPP Search ===");
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
            const char *ns=class_get_namespace?class_get_namespace(klass):NULL;
            if(cn&&strcmp(cn,"Actor")==0&&!g_classActor) g_classActor=klass;
            if(cn&&strcmp(cn,"GameEntry")==0&&g_gameEntryCount<MAX_GAME_ENTRIES){
                g_allGameEntries[g_gameEntryCount]=klass;
                g_allGameEntryNS[g_gameEntryCount]=ns?strdup(ns):NULL;
                g_gameEntryCount++;
                if(ns&&strcmp(ns,"UnityGameFramework.Runtime")==0&&!g_classUnityGameEntry) g_classUnityGameEntry=klass;
                if(ns&&strcmp(ns,"HotfixFramework.Runtime")==0&&!g_classHotfixGameEntry) g_classHotfixGameEntry=klass;
            }
            if(cn&&strcmp(cn,"ConfigComponent")==0){
                if(ns&&strcmp(ns,"HotfixFramework.Runtime")==0&&!g_classHotfixConfigComponent) g_classHotfixConfigComponent=klass;
                if(ns&&strcmp(ns,"UnityGameFramework.Runtime")==0&&!g_classConfigComponent) g_classConfigComponent=klass;
            }
            // v106: 搜索LoginModel类 (Singleton, 保存CurSSOResponData)
            if(cn&&strcmp(cn,"LoginModel")==0&&ns&&strcmp(ns,"HotfixBusiness.Procedure")==0&&!g_classLoginModel){
                g_classLoginModel=klass; jlog(@"FOUND LoginModel class: %p",klass);
            }
            // v106: 搜索LoginCtrl类 (有DoHandShakeCheck方法)
            if(cn&&strcmp(cn,"LoginCtrl")==0&&ns&&strcmp(ns,"HotfixBusiness.UI")==0&&!g_classLoginCtrl){
                g_classLoginCtrl=klass; jlog(@"FOUND LoginCtrl class: %p",klass);
            }
            void *iter=NULL,*m=NULL;
            while((m=get_methods(klass,&iter))!=NULL){
                totalMethods++;
                const char *n=method_name(m); if(!n)continue;
                uint32_t pc=param_count?param_count(m):0;
                void *fa=NULL; memcpy(&fa,m,sizeof(void*));
                if(strcmp(n,"CheckSkillUnlock")==0&&!g_fUnlock){g_fUnlock=fa;found++;}
                else if(strcmp(n,"get_limitDamage")==0&&!g_fLimitDmg){g_fLimitDmg=fa;found++;}
                else if(strcmp(n,"CheckSkillIsReady")==0&&!g_fIsReady){g_fIsReady=fa;found++;}
                else if(strcmp(n,"CheckSkillAttackCanUse")==0&&!g_fAttackCanUse){g_fAttackCanUse=fa;found++;}
                else if(strcmp(n,"CanBeAttack")==0&&!g_fCanBeAttack){g_fCanBeAttack=fa;found++;}
                else if(strcmp(n,"Damage")==0&&pc>=10&&!g_fDamage){g_fDamage=fa;found++;}
                else if(strcmp(n,"DecreaseHP")==0&&pc==5){if(!g_origDecreaseHP)g_origDecreaseHP=(DecreaseHPFunc)fa;}
                else if(strcmp(n,"Intersects")==0&&pc==1&&cn&&strstr(cn,"FPBounds2")!=NULL&&!g_fIntersects){g_fIntersects=fa;found++;}
                else if(strcmp(n,"CheckPlayerHitCollider")==0&&pc==2&&!g_fCheckHit){g_fCheckHit=fa;found++;}
                else if(strcmp(n,"Update")==0&&pc==1&&cn&&strcmp(cn,"HitSystem")==0&&!g_fHitSystemUpdate){g_fHitSystemUpdate=fa;found++;}
                // v106: LoginCtrl.DoHandShakeCheck(int32 code) — 唯一地址0x2b7eb2c, 不被泛型共享
                else if(strcmp(n,"DoHandShakeCheck")==0&&pc==1&&cn&&strcmp(cn,"LoginCtrl")==0&&!g_fDoHandShakeCheck){g_fDoHandShakeCheck=fa;found++;jlog(@"FOUND %s.%s p=%u %p",cn,n,pc,fa);}
                // v102→v106: 保留get_code/get_banTime搜索仅用于日志确认, 不再MSHookFunction它们
                else if(strcmp(n,"get_code")==0&&pc==0&&cn&&strcmp(cn,"SSOResponData")==0&&!g_fGetCode){g_fGetCode=fa;jlog(@"FOUND %s.%s p=%u %p (NOT hooking - shared addr)",cn,n,pc,fa);}
                else if(strcmp(n,"get_banTime")==0&&pc==0&&cn&&strcmp(cn,"SSOResponData")==0&&!g_fGetBanTime){g_fGetBanTime=fa;jlog(@"FOUND %s.%s p=%u %p (NOT hooking - shared addr)",cn,n,pc,fa);}
                // v102: 禁用皮肤hook (get_SkinId和InitWithSkinId在MSHookFunction下参数错位)
                else if(strcmp(n,"HandleSkillRange")==0&&pc>=3&&!g_fHandleSkillRange){g_fHandleSkillRange=fa;found++;}
                else if(strcmp(n,"UseSkill")==0&&pc>=7&&cn&&strcmp(cn,"AttackSystem")==0&&!g_fUseSkill){g_fUseSkill=fa;found++;}
                else if(strcmp(n,"UpdateSkillCoolDown")==0&&pc>=3&&cn&&strcmp(cn,"AttackSystem")==0&&!g_fUpdateSkillCD){g_fUpdateSkillCD=fa;found++;}
                else if(strcmp(n,"MoveStep")==0&&pc>=7&&!g_fMoveStep){g_fMoveStep=fa;found++;}
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
    g_il2cppDone=YES;
    jlog(@"v83: found %d targets, scanned %d methods",found,totalMethods);
    jlog(@"v83: limitDmg=%p IsReady=%p AttackCanUse=%p CanBeAttack=%p Damage=%p",
         g_fLimitDmg,g_fIsReady,g_fAttackCanUse,g_fCanBeAttack,g_fDamage);
    jlog(@"v83: Intersects=%p CheckHit=%p HitSysUpd=%p MoveStep=%p",
         g_fIntersects,g_fCheckHit,g_fHitSystemUpdate,g_fMoveStep);
    jlog(@"v83: UseSkill=%p UpdateSkillCD=%p HandleSkillRange=%p Unlock=%p",
         g_fUseSkill,g_fUpdateSkillCD,g_fHandleSkillRange,g_fUnlock);
    jlog(@"v83: getSkinId=%p InitWithSkinId=%p Actor=%p",
         g_fGetSkinId,g_fInitWithSkinId,g_classActor);
    // v106: 用il2cpp_class_from_name搜索热更新DLL中的LoginModel/LoginCtrl/DoHandShakeCheck
    if((!g_fDoHandShakeCheck || !g_classLoginModel) && get_image && class_count && get_class && get_methods && method_name && param_count) {
        typedef void* (*Il2CppClassFromName)(void*,const char*,const char*);
        Il2CppClassFromName class_from_name=dlsym(h,"il2cpp_class_from_name");
        if(class_from_name) {
            for(size_t a=0;a<assemCount;a++){
                void *img=get_image(assemblies[a]); if(!img)continue;
                // 搜索LoginModel (HotfixBusiness.Procedure命名空间)
                if(!g_classLoginModel) {
                    void *lmClass=class_from_name(img,"HotfixBusiness.Procedure","LoginModel");
                    if(lmClass) {
                        g_classLoginModel=lmClass;
                        jlog(@"v106: Found LoginModel class in assembly %zu: %p", a, lmClass);
                    }
                }
                // 搜索LoginCtrl (HotfixBusiness.UI命名空间) — 找DoHandShakeCheck
                if(!g_fDoHandShakeCheck) {
                    void *lcClass=class_from_name(img,"HotfixBusiness.UI","LoginCtrl");
                    if(lcClass) {
                        g_classLoginCtrl=lcClass;
                        jlog(@"v106: Found LoginCtrl class in assembly %zu: %p", a, lcClass);
                        void *iter2=NULL,*m2=NULL;
                        while((m2=get_methods(lcClass,&iter2))!=NULL){
                            const char *mn=method_name(m2);
                            uint32_t mp=param_count?param_count(m2):0;
                            void *mfa=NULL; memcpy(&mfa,m2,sizeof(void*));
                            if(mn&&strcmp(mn,"DoHandShakeCheck")==0&&mp==1&&!g_fDoHandShakeCheck){
                                g_fDoHandShakeCheck=mfa; found++;
                                jlog(@"FOUND LoginCtrl.DoHandShakeCheck p=%u %p (unique addr!)", mp, mfa);
                            }
                        }
                    }
                }
                // 同时搜索SSOResponData确认存在(仅日志)
                if(!g_fGetCode) {
                    void *ssoRspClass=class_from_name(img,"HotfixBusiness.Procedure","SSOResponData");
                    if(ssoRspClass) {
                        jlog(@"v106: Found SSOResponData class: %p", ssoRspClass);
                        void *iter3=NULL,*m3=NULL;
                        while((m3=get_methods(ssoRspClass,&iter3))!=NULL){
                            const char *mn=method_name(m3);
                            uint32_t mp=param_count?param_count(m3):0;
                            void *mfa=NULL; memcpy(&mfa,m3,sizeof(void*));
                            if(mn&&strcmp(mn,"get_code")==0&&!g_fGetCode){g_fGetCode=mfa;jlog(@"  SSOResponData.get_code p=%u %p (NOT hooking - shared)",mp,mfa);}
                            if(mn&&strcmp(mn,"get_banTime")==0&&!g_fGetBanTime){g_fGetBanTime=mfa;jlog(@"  SSOResponData.get_banTime p=%u %p (NOT hooking - shared)",mp,mfa);}
                        }
                    }
                }
                if(g_fDoHandShakeCheck && g_classLoginModel) break;
            }
        }
    }
    jlog(@"v106: DoHandShakeCheck=%p LoginModel=%p LoginCtrl=%p",
         g_fDoHandShakeCheck, g_classLoginModel, g_classLoginCtrl);
    if(!g_fDoHandShakeCheck) jlog(@"v106: DoHandShakeCheck NOT FOUND!");
    if(!g_classLoginModel) jlog(@"v106: LoginModel class NOT FOUND!");
}

static void hookOneFunc(void *fa,void *hf,void **of,BOOL *hf2,const char *name){
    if(!fa){jlog(@"%s: not found",name);return;}
    if(*hf2){jlog(@"%s: already hooked",name);return;}
    jlog(@"%s: hooking %p via MSHookFunction...",name,fa);
    MSHookFunction(fa,hf,of);
    *hf2=YES;
    jlog(@"%s: OK orig=%p",name,*of);
}

// v83: 不自动hook! applyAllHooks为空 (用MSHookFunction替代DobbyHook)
static void applyAllHooks(void){jlog(@"v83: applyAllHooks skipped (lazy hook mode)");}

// ===== UI =====
static UIView *g_panel=nil;
static UIScrollView *g_scrollView=nil;
static UIButton *g_btnIgnoreUnlock=nil,*g_btnExSkillNoCD=nil,*g_btnGodMode=nil,*g_btnFullScreen=nil,*g_btnSkillReplace=nil,*g_btnApplySkin=nil,*g_btnScanSkin=nil,*g_btnBypassSSO=nil;
static UIButton *g_btnRepS1=nil,*g_btnRepS2=nil,*g_btnRepS3=nil,*g_btnRepS4=nil,*g_btnRepS5=nil;
static UISlider *g_slider=nil,*g_skinSlider=nil,*g_weaponSlider=nil,*g_speedSlider=nil;
static UILabel *g_sliderLabel=nil,*g_skinLabel=nil,*g_weaponLabel=nil,*g_speedLabel=nil;
static BOOL g_panelOpen=NO;
static CGFloat g_panelW=360, g_panelH=600;
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
-(void)onBypassSSO;
-(void)onApplySkin;
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
    if(g_skillReplace){[g_btnSkillReplace setTitle:@"ON  \xe6\x8a\x80\xe8\x83\xbd\xe6\x9b\xbf\xe6\x8d\xa2" forState:UIControlStateNormal];g_btnSkillReplace.backgroundColor=IMGUI_BTN_ON;g_btnSkillReplace.layer.borderColor=IMGUI_GREEN.CGColor;}
    else{[g_btnSkillReplace setTitle:@"OFF \xe6\x8a\x80\xe8\x83\xbd\xe6\x9b\xbf\xe6\x8d\xa2" forState:UIControlStateNormal];g_btnSkillReplace.backgroundColor=IMGUI_BTN_OFF;g_btnSkillReplace.layer.borderColor=IMGUI_RED.CGColor;}
    if(g_replaceSkill1){[g_btnRepS1 setTitle:@"1\xE2\x86\x92\xe5\xa4\xa7" forState:UIControlStateNormal];g_btnRepS1.backgroundColor=IMGUI_BTN_ON;g_btnRepS1.layer.borderColor=IMGUI_GREEN.CGColor;}
    else{[g_btnRepS1 setTitle:@"1" forState:UIControlStateNormal];g_btnRepS1.backgroundColor=[UIColor colorWithRed:0.15 green:0.15 blue:0.18 alpha:0.95];g_btnRepS1.layer.borderColor=IMGUI_BORDER.CGColor;}
    if(g_replaceSkill2){[g_btnRepS2 setTitle:@"2\xE2\x86\x92\xe5\xa4\xa7" forState:UIControlStateNormal];g_btnRepS2.backgroundColor=IMGUI_BTN_ON;g_btnRepS2.layer.borderColor=IMGUI_GREEN.CGColor;}
    else{[g_btnRepS2 setTitle:@"2" forState:UIControlStateNormal];g_btnRepS2.backgroundColor=[UIColor colorWithRed:0.15 green:0.15 blue:0.18 alpha:0.95];g_btnRepS2.layer.borderColor=IMGUI_BORDER.CGColor;}
    if(g_replaceSkill3){[g_btnRepS3 setTitle:@"3\xE2\x86\x92\xe5\xa4\xa7" forState:UIControlStateNormal];g_btnRepS3.backgroundColor=IMGUI_BTN_ON;g_btnRepS3.layer.borderColor=IMGUI_GREEN.CGColor;}
    else{[g_btnRepS3 setTitle:@"3" forState:UIControlStateNormal];g_btnRepS3.backgroundColor=[UIColor colorWithRed:0.15 green:0.15 blue:0.18 alpha:0.95];g_btnRepS3.layer.borderColor=IMGUI_BORDER.CGColor;}
    if(g_replaceSkill4){[g_btnRepS4 setTitle:@"4\xE2\x86\x92\xe5\xa4\xa7" forState:UIControlStateNormal];g_btnRepS4.backgroundColor=IMGUI_BTN_ON;g_btnRepS4.layer.borderColor=IMGUI_GREEN.CGColor;}
    else{[g_btnRepS4 setTitle:@"4" forState:UIControlStateNormal];g_btnRepS4.backgroundColor=[UIColor colorWithRed:0.15 green:0.15 blue:0.18 alpha:0.95];g_btnRepS4.layer.borderColor=IMGUI_BORDER.CGColor;}
    if(g_replaceSkill5){[g_btnRepS5 setTitle:@"5\xE2\x86\x92\xe5\xa4\xa7" forState:UIControlStateNormal];g_btnRepS5.backgroundColor=IMGUI_BTN_ON;g_btnRepS5.layer.borderColor=IMGUI_GREEN.CGColor;}
    else{[g_btnRepS5 setTitle:@"5" forState:UIControlStateNormal];g_btnRepS5.backgroundColor=[UIColor colorWithRed:0.15 green:0.15 blue:0.18 alpha:0.95];g_btnRepS5.layer.borderColor=IMGUI_BORDER.CGColor;}
    if(g_btnApplySkin){
        // v102: 皮肤功能禁用
        [g_btnApplySkin setTitle:@"\xe7\x9a\xae\xe8\x82\xa4(\xe5\xb7\xb2\xe7\xa6\x81\xe7\x94\xa8)" forState:UIControlStateNormal];
        g_btnApplySkin.backgroundColor=[UIColor colorWithRed:0.35 green:0.14 blue:0.14 alpha:0.95];g_btnApplySkin.layer.borderColor=IMGUI_RED.CGColor;
    }
    if(g_btnScanSkin){
        if(g_skinIdsLoaded){[g_btnScanSkin setTitle:[NSString stringWithFormat:@"\xe5\xb7\xb2\xe6\x89\xab\xe6\x8f\x8f:\xe7\x9a\xae\xe8\x82\xa4%d/\xe6\xad\xa6\xe5\x99\xa8%d",g_roleSkinCount,g_weaponSkinCount] forState:UIControlStateNormal];g_btnScanSkin.backgroundColor=[UIColor colorWithRed:0.16 green:0.52 blue:0.28 alpha:0.95];}
        else{[g_btnScanSkin setTitle:@"\xe6\x89\xab\xe6\x8f\x8f\xe7\x9a\xae\xe8\x82\xa4ID" forState:UIControlStateNormal];g_btnScanSkin.backgroundColor=[UIColor colorWithRed:0.18 green:0.35 blue:0.55 alpha:0.95];}
        g_btnScanSkin.layer.borderColor=IMGUI_ACCENT.CGColor;
    }
    // v102: SSO检测跳过
    if(g_btnBypassSSO){
        if(g_bypassSSO){[g_btnBypassSSO setTitle:@"ON  \xe8\xb7\xb3\xe8\xbf\x87SSO\xe6\xa3\x80\xe6\xb5\x8b" forState:UIControlStateNormal];g_btnBypassSSO.backgroundColor=IMGUI_BTN_ON;g_btnBypassSSO.layer.borderColor=IMGUI_GREEN.CGColor;}
        else{[g_btnBypassSSO setTitle:@"OFF \xe8\xb7\xb3\xe8\xbf\x87SSO\xe6\xa3\x80\xe6\xb5\x8b" forState:UIControlStateNormal];g_btnBypassSSO.backgroundColor=IMGUI_BTN_OFF;g_btnBypassSSO.layer.borderColor=IMGUI_RED.CGColor;}
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
        if(!g_hCanBeAttack)hookOneFunc(g_fCanBeAttack,hCanBeAttack,(void**)&g_oCanBeAttack,&g_hCanBeAttack,"CanBeAttack");
        if(!g_hDamage)hookOneFunc(g_fDamage,hDamage,(void**)&g_oDamage,&g_hDamage,"Damage");
    }
    refreshBtns();
}
-(void)onBypassSSO{
    g_bypassSSO=!g_bypassSSO;
    if(g_bypassSSO){findIL2CPP();
        // v106: 优先hook DoHandShakeCheck (唯一地址, 不被泛型共享)
        if(g_fDoHandShakeCheck && !g_hDoHandShakeCheck) {
            hookOneFunc(g_fDoHandShakeCheck,hDoHandShakeCheck,(void**)&g_oDoHandShakeCheck,&g_hDoHandShakeCheck,"DoHandShakeCheck");
        } else if(!g_fDoHandShakeCheck) {
            jlog(@"bypassSSO: DoHandShakeCheck not found, trying memory patch...");
        }
        // 备用: 直接内存修改LoginModel.CurSSOResponData
        patchSSOResponDataMemory();
        // 启动定时器持续修补 (SSO响应可能在bypass开启后才到达)
        static BOOL timerStarted=NO;
        if(!timerStarted) {
            timerStarted=YES;
            // 每2秒检查一次, 最多检查30次(60秒)
            __block int checkCount=0;
            dispatch_source_t timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
            dispatch_source_set_timer(timer,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),2*NSEC_PER_SEC,0);
            dispatch_source_set_event_handler(timer,^{
                if(!g_bypassSSO||checkCount>=30){dispatch_source_cancel(timer);return;}
                checkCount++;
                patchSSOResponDataMemory();
            });
            dispatch_resume(timer);
        }
    }
    jlog(@"bypassSSO: %d (DoHandShakeCheck=%p)", g_bypassSSO, g_fDoHandShakeCheck);
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
    if(g_speedMul>1.0f && !g_hMoveStep) {
        findIL2CPP();
        hookOneFunc(g_fMoveStep,hMoveStep,(void**)&g_oMoveStep,&g_hMoveStep,"MoveStep");
    }
    g_speedLabel.text=[NSString stringWithFormat:@"\xe7\xa7\xbb\xe5\x8a\xa8\xe9\x80\x9f\xe5\xba\xa6: %.1fx",g_speedMul];
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
-(void)onDumpSkinIds{
    if(!g_classUnityGameEntry&&!g_classHotfixGameEntry) findIL2CPP();
    if(g_skinIdsLoaded){refreshBtns();return;}
    scanSkinIds();
    refreshBtns();
}
-(void)sliderChanged:(UISlider*)s{g_damageLimit=(int)s.value;g_sliderLabel.text=[NSString stringWithFormat:@"\xe4\xbc\xa4\xe5\xae\xb3\xe4\xb8\x8a\xe9\x99\x90: %d",g_damageLimit];
    // v82: 滑动伤害上限时, 如果还没hook limitDmg, 就hook
    if(!g_hLimitDmg){findIL2CPP();hookOneFunc(g_fLimitDmg,hLimitDmg,(void**)&g_oLimitDmg,&g_hLimitDmg,"limitDmg");}
}
-(void)skinSliderChanged:(UISlider*)s{
    int idx=(int)s.value;
    if(g_skinIdsLoaded){if(idx>=g_roleSkinCount)idx=g_roleSkinCount-1;if(idx<0)idx=0;g_skinId=g_roleSkinIds[idx];}
    else g_skinId=idx;
    g_skinLabel.text=[NSString stringWithFormat:@"\xe7\x9a\xae\xe8\x82\xa4" "ID: %d",g_skinId];
}
-(void)weaponSliderChanged:(UISlider*)s{
    int idx=(int)s.value;
    if(g_skinIdsLoaded){if(idx>=g_weaponSkinCount)idx=g_weaponSkinCount-1;if(idx<0)idx=0;g_weaponId=g_weaponSkinIds[idx];}
    else g_weaponId=idx;
    g_weaponLabel.text=[NSString stringWithFormat:@"\xe6\xad\xa6\xe5\x99\xa8" "ID: %d",g_weaponId];
}
-(void)onApplySkin{
    // v102: 皮肤hook禁用 — MSHookFunction参数错位导致卡死
    jlog(@"ApplySkin: DISABLED in v102 (hook parameter misalignment causes freeze)");
    return;
    if(!g_skinIdsLoaded){jlog(@"ApplySkin: scan first");return;}
    if(!g_fGetSkinId){jlog(@"ApplySkin: get_SkinId not found");return;}
    if(!g_hGetSkinId) hookOneFunc(g_fGetSkinId,hGetSkinId,(void**)&g_oGetSkinId,&g_hGetSkinId,"get_SkinId");
    g_appliedSkinId=g_skinId; g_appliedWeaponId=g_weaponId;
    if(g_playerActorObj && g_fInitWithSkinId) {
        jlog(@"ApplySkin: calling InitWithSkinId(%d, 2)", g_skinId);
        @try {
            ((InitWithSkinIdFunc)g_fInitWithSkinId)(g_playerActorObj, g_skinId, 2);
            jlog(@"ApplySkin: InitWithSkinId OK");
        } @catch(NSException *e) {
            jlog(@"ApplySkin: EXCEPTION: %@", e);
        }
    } else if(!g_playerActorObj) {
        jlog(@"ApplySkin: Actor not found yet");
    }
    jlog(@"ApplySkin: skin=%d weapon=%d",g_skinId,g_weaponId);
}
@end

@interface JYJHResizeHandle : UIView { CGPoint _ts; }
@end
@implementation JYJHResizeHandle
-(instancetype)init{self=[super initWithFrame:CGRectMake(0,0,36,36)];if(self){self.backgroundColor=[UIColor clearColor];self.layer.zPosition=9999;UIView *t=[[UIView alloc]initWithFrame:CGRectMake(0,0,36,36)];t.backgroundColor=[UIColor colorWithRed:0.3 green:0.3 blue:0.4 alpha:0.85];t.layer.cornerRadius=6;[self addSubview:t];UILabel *l=[[UILabel alloc]initWithFrame:CGRectMake(0,0,36,36)];l.text=@"\xe2\x87\x98";l.textColor=[UIColor whiteColor];l.font=[UIFont systemFontOfSize:18];l.textAlignment=NSTextAlignmentCenter;[self addSubview:l];}return self;}
-(BOOL)pointInside:(CGPoint)p withEvent:(UIEvent*)e{return CGRectContainsPoint(CGRectInset(self.bounds,-6,-6),p);}
-(void)touchesBegan:(NSSet*)t withEvent:(UIEvent*)e{_ts=[[t anyObject]locationInView:g_panel.superview];}
-(void)touchesMoved:(NSSet*)t withEvent:(UIEvent*)e{CGPoint c=[[t anyObject]locationInView:g_panel.superview];CGFloat nw=MAX(200,c.x-g_panel.frame.origin.x);CGFloat nh=MAX(300,c.y-g_panel.frame.origin.y);g_panelW=nw;g_panelH=nh;g_panel.frame=CGRectMake(g_panel.frame.origin.x,g_panel.frame.origin.y,nw,nh);if(g_scrollView){g_scrollView.frame=CGRectMake(0,32,nw,nh-32);g_scrollView.contentSize=CGSizeMake(nw,g_scrollView.contentSize.height);}if(g_resizeHandle)g_resizeHandle.frame=CGRectMake(g_panel.frame.origin.x+nw-36,g_panel.frame.origin.y+nh-36,36,36);if(g_resizeHandleTop)g_resizeHandleTop.frame=CGRectMake(g_panel.frame.origin.x+nw-36,g_panel.frame.origin.y,36,36);}
@end

@interface JYJHTitleDragView : UIView { CGPoint _ts; }
@end
@implementation JYJHTitleDragView
-(void)touchesBegan:(NSSet*)t withEvent:(UIEvent*)e{_ts=[[t anyObject]locationInView:g_panel.superview];}
-(void)touchesMoved:(NSSet*)t withEvent:(UIEvent*)e{CGPoint c=[[t anyObject]locationInView:g_panel.superview];CGFloat dx=c.x-_ts.x,dy=c.y-_ts.y;CGRect f=g_panel.frame;CGRect sc=[UIScreen mainScreen].bounds;f.origin.x=MAX(-f.size.width+40,MIN(sc.size.width-40,f.origin.x+dx));f.origin.y=MAX(-20,MIN(sc.size.height-60,f.origin.y+dy));g_panel.frame=f;if(g_resizeHandle)g_resizeHandle.frame=CGRectMake(f.origin.x+g_panelW-36,f.origin.y+g_panelH-36,36,36);if(g_resizeHandleTop)g_resizeHandleTop.frame=CGRectMake(f.origin.x+g_panelW-36,f.origin.y,36,36);_ts=c;}
@end

@interface JYJHBallView : UIView { CGPoint _ts; BOOL _drag; }
@end
@implementation JYJHBallView
-(instancetype)init{self=[super initWithFrame:CGRectMake([UIScreen mainScreen].bounds.size.width-46,150,40,40)];if(self){self.backgroundColor=IMGUI_BALL_BG;self.layer.cornerRadius=20;self.layer.borderWidth=2;self.layer.borderColor=IMGUI_ACCENT.CGColor;self.userInteractionEnabled=YES;UILabel*l=[[UILabel alloc]initWithFrame:CGRectMake(0,0,40,40)];l.text=@"\xe5\x89\x91";l.textColor=[UIColor whiteColor];l.font=[UIFont boldSystemFontOfSize:18];l.textAlignment=NSTextAlignmentCenter;[self addSubview:l];}return self;}
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
    JYJHTitleDragView *tb=[[JYJHTitleDragView alloc]initWithFrame:CGRectMake(0,0,g_panelW,32)];tb.backgroundColor=IMGUI_TITLE_BG;[outer addSubview:tb];
    UILabel *tl=[[UILabel alloc]initWithFrame:CGRectMake(10,6,g_panelW-20,20)];tl.text=@"\xe5\x89\x91\xe5\xbd\xb1\xe6\xb1\x9f\xe6\xb9\x96 v104";tl.textColor=IMGUI_ACCENT;tl.font=[UIFont boldSystemFontOfSize:15];tl.textAlignment=NSTextAlignmentCenter;[tb addSubview:tl];
    UIScrollView *sv=[[UIScrollView alloc]initWithFrame:CGRectMake(0,32,g_panelW,g_panelH-32)];sv.showsVerticalScrollIndicator=YES;sv.delaysContentTouches=NO;sv.canCancelContentTouches=YES;[outer addSubview:sv]; g_scrollView=sv;
    CGFloat bx=12,bw=g_panelW-24,bh=24,by0=4,bdy=28;
    CGFloat contentH=by0+bdy*6+60+220;
    sv.contentSize=CGSizeMake(g_panelW,contentH);
    g_btnIgnoreUnlock=mkBtn(CGRectMake(bx,by0,bw,bh),@selector(onIgnoreUnlock));[sv addSubview:g_btnIgnoreUnlock];
    g_btnExSkillNoCD=mkBtn(CGRectMake(bx,by0+bdy,bw,bh),@selector(onExSkillNoCD));[sv addSubview:g_btnExSkillNoCD];
    g_btnGodMode=mkBtn(CGRectMake(bx,by0+bdy*2,bw,bh),@selector(onGodMode));[sv addSubview:g_btnGodMode];
    g_btnFullScreen=mkBtn(CGRectMake(bx,by0+bdy*3,bw,bh),@selector(onFullScreen));[sv addSubview:g_btnFullScreen];
    g_btnSkillReplace=mkBtn(CGRectMake(bx,by0+bdy*4,bw,bh),@selector(onSkillReplace));[sv addSubview:g_btnSkillReplace];
    CGFloat repY=by0+bdy*5;
    CGFloat sbw=(bw-4*5)/5;
    g_btnRepS1=mkBtn(CGRectMake(bx,repY,sbw,bh),@selector(onReplaceS1));[sv addSubview:g_btnRepS1];
    g_btnRepS2=mkBtn(CGRectMake(bx+sbw+4,repY,sbw,bh),@selector(onReplaceS2));[sv addSubview:g_btnRepS2];
    g_btnRepS3=mkBtn(CGRectMake(bx+(sbw+4)*2,repY,sbw,bh),@selector(onReplaceS3));[sv addSubview:g_btnRepS3];
    g_btnRepS4=mkBtn(CGRectMake(bx+(sbw+4)*3,repY,sbw,bh),@selector(onReplaceS4));[sv addSubview:g_btnRepS4];
    g_btnRepS5=mkBtn(CGRectMake(bx+(sbw+4)*4,repY,sbw,bh),@selector(onReplaceS5));[sv addSubview:g_btnRepS5];
    CGFloat s1Y=by0+bdy*6;UIView *s1=[[UIView alloc]initWithFrame:CGRectMake(bx,s1Y,bw,1)];s1.backgroundColor=IMGUI_BORDER;[sv addSubview:s1];
    CGFloat sy=s1Y+8;
    g_sliderLabel=[[UILabel alloc]initWithFrame:CGRectMake(bx,sy,bw,18)];g_sliderLabel.text=[NSString stringWithFormat:@"\xe4\xbc\xa4\xe5\xae\xb3\xe4\xb8\x8a\xe9\x99\x90: %d",g_damageLimit];g_sliderLabel.textColor=IMGUI_DIMTEXT;g_sliderLabel.font=[UIFont systemFontOfSize:12];[sv addSubview:g_sliderLabel];
    g_slider=[[UISlider alloc]initWithFrame:CGRectMake(bx,sy+20,bw,28)];g_slider.minimumValue=1;g_slider.maximumValue=5000;g_slider.value=g_damageLimit;[g_slider addTarget:[JYJHActionHandler shared] action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];[sv addSubview:g_slider];
    CGFloat s2Y=sy+52;UIView *s2=[[UIView alloc]initWithFrame:CGRectMake(bx,s2Y,bw,1)];s2.backgroundColor=IMGUI_BORDER;[sv addSubview:s2];
    CGFloat ssy=s2Y+6;
    UILabel *secT=[[UILabel alloc]initWithFrame:CGRectMake(bx,ssy,bw,18)];
    secT.text=g_skinIdsLoaded?[NSString stringWithFormat:@"\xe7\x9a\xae\xe8\x82\xa4/\xe6\xad\xa6\xe5\x99\xa8(\xe7\x9a\xae\xe8\x82\xa4%d/\xe6\xad\xa6\xe5\x99\xa8%d)",g_roleSkinCount,g_weaponSkinCount]:@"\xe7\x9a\xae\xe8\x82\xa4/\xe6\xad\xa6\xe5\x99\xa8(\xe5\x85\x88\xe6\x89\xab\xe6\x8f\x8f)";
    secT.textColor=IMGUI_ACCENT;secT.font=[UIFont boldSystemFontOfSize:11];[sv addSubview:secT];
    g_skinLabel=[[UILabel alloc]initWithFrame:CGRectMake(bx,ssy+20,bw,18)];g_skinLabel.text=@"\xe7\x9a\xae\xe8\x82\xa4ID: 0";g_skinLabel.textColor=IMGUI_DIMTEXT;g_skinLabel.font=[UIFont systemFontOfSize:12];[sv addSubview:g_skinLabel];
    g_skinSlider=[[UISlider alloc]initWithFrame:CGRectMake(bx,ssy+38,bw,28)];g_skinSlider.minimumValue=0;g_skinSlider.maximumValue=g_skinIdsLoaded?g_roleSkinCount-1:2000;g_skinSlider.value=0;[g_skinSlider addTarget:[JYJHActionHandler shared] action:@selector(skinSliderChanged:) forControlEvents:UIControlEventValueChanged];[sv addSubview:g_skinSlider];
    g_weaponLabel=[[UILabel alloc]initWithFrame:CGRectMake(bx,ssy+68,bw,18)];g_weaponLabel.text=@"\xe6\xad\xa6\xe5\x99\xa8ID: 0";g_weaponLabel.textColor=IMGUI_DIMTEXT;g_weaponLabel.font=[UIFont systemFontOfSize:12];[sv addSubview:g_weaponLabel];
    g_weaponSlider=[[UISlider alloc]initWithFrame:CGRectMake(bx,ssy+86,bw,28)];g_weaponSlider.minimumValue=0;g_weaponSlider.maximumValue=g_skinIdsLoaded?g_weaponSkinCount-1:2000;g_weaponSlider.value=0;[g_weaponSlider addTarget:[JYJHActionHandler shared] action:@selector(weaponSliderChanged:) forControlEvents:UIControlEventValueChanged];[sv addSubview:g_weaponSlider];
    g_btnApplySkin=mkBtn(CGRectMake(bx,ssy+118,bw,bh),@selector(onApplySkin));[sv addSubview:g_btnApplySkin];
    g_btnScanSkin=mkBtn(CGRectMake(bx,ssy+146,bw,bh),@selector(onDumpSkinIds));[sv addSubview:g_btnScanSkin];
    CGFloat s3Y=ssy+174;UIView *s3=[[UIView alloc]initWithFrame:CGRectMake(bx,s3Y,bw,1)];s3.backgroundColor=IMGUI_BORDER;[sv addSubview:s3];
    CGFloat spy=s3Y+4;
    // v102: SSO检测跳过按钮
    g_btnBypassSSO=mkBtn(CGRectMake(bx,spy,bw,bh),@selector(onBypassSSO));[sv addSubview:g_btnBypassSSO];
    CGFloat s4Y=spy+34;UIView *s4=[[UIView alloc]initWithFrame:CGRectMake(bx,s4Y,bw,1)];s4.backgroundColor=IMGUI_BORDER;[sv addSubview:s4];
    CGFloat ssy2=s4Y+4;
    g_speedLabel=[[UILabel alloc]initWithFrame:CGRectMake(bx,ssy2,bw,18)];g_speedLabel.text=@"\xe7\xa7\xbb\xe5\x8a\xa8\xe9\x80\x9f\xe5\xba\xa6: 1.0x";g_speedLabel.textColor=IMGUI_ACCENT;g_speedLabel.font=[UIFont boldSystemFontOfSize:12];[sv addSubview:g_speedLabel];
    g_speedSlider=[[UISlider alloc]initWithFrame:CGRectMake(bx,ssy2+20,bw,28)];g_speedSlider.minimumValue=1.0;g_speedSlider.maximumValue=5.0;g_speedSlider.value=1.0;[g_speedSlider addTarget:[JYJHActionHandler shared] action:@selector(speedSliderChanged:) forControlEvents:UIControlEventValueChanged];[sv addSubview:g_speedSlider];
    g_resizeHandle=[[JYJHResizeHandle alloc]init];CGRect pf=g_panel.frame;g_resizeHandle.frame=CGRectMake(pf.origin.x+g_panelW-36,pf.origin.y+g_panelH-36,36,36);g_resizeHandle.hidden=YES;[win addSubview:g_resizeHandle];
    g_resizeHandleTop=[[JYJHResizeHandle alloc]init];g_resizeHandleTop.frame=CGRectMake(pf.origin.x+g_panelW-36,pf.origin.y,36,36);g_resizeHandleTop.hidden=YES;[win addSubview:g_resizeHandleTop];
    refreshBtns();
}

// v83: 启动时只findIL2CPP, 不自动hook任何函数!
// 所有hook都是懒加载 - 点按钮才hook
// 使用MSHookFunction (CydiaSubstrate) 替代DobbyHook
__attribute__((constructor))
static void initialize(void){
    static BOOL loaded=NO; if(loaded)return; loaded=YES;
    jlog(@"========== JYJH v106 (SSO bypass: get_method_from_name+Nested) ==========");
    jlog(@"iOS %@",[[UIDevice currentDevice] systemVersion]);
    // 检查MSHookFunction是否可用
    void *sub=dlopen("CydiaSubstrate",RTLD_LAZY);
    if(!sub) sub=dlopen("/usr/lib/libsubstrate.dylib",RTLD_LAZY);
    if(!sub) sub=dlopen("@executable_path/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",RTLD_LAZY);
    if(!sub) jlog(@"WARNING: CydiaSubstrate not found via dlopen, relying on dynamic_lookup");
    else jlog(@"CydiaSubstrate loaded: %p", sub);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(5.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        jlog(@"5s: findIL2CPP only (no auto-hook)...");
        findIL2CPP();
        jlog(@"5s: findIL2CPP done, setting up UI...");
        setupUI();
        jlog(@"5s: UI setup done - all hooks are lazy (click to activate)");
    });
}
