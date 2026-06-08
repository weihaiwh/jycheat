/**
 * 剑影江湖 v1.10.1 - v7.0
 * 使用IL2CPP运行时API查找方法地址
 */
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <dispatch/dispatch.h>
#import <UIKit/UIKit.h>
#import <stdio.h>
#import <string.h>
#import <dlfcn.h>

extern void sys_icache_invalidate(void *start, size_t len);

static FILE *g_logFile = NULL;
static NSMutableArray *g_debugLines = nil;
static UILabel *g_debugLabel = nil;

static void jlog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[JYJH] %@", msg);
    if (g_debugLines) { [g_debugLines addObject:msg]; if(g_debugLines.count>30)[g_debugLines removeObjectAtIndex:0]; }
    if (g_debugLabel) g_debugLabel.text = [g_debugLines componentsJoinedByString:@"\n"];
    if (!g_logFile) {
        NSString *p = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/jyjh.log"];
        g_logFile = fopen([p UTF8String], "a");
    }
    if (g_logFile) { fprintf(g_logFile, "%s\n", [msg UTF8String]); fflush(g_logFile); }
}

static BOOL g_noCD = YES;
static BOOL g_noEnergy = YES;
static int g_damageLimit = 10000;
static void *g_ptrCanUse = NULL;
static void *g_ptrIsReady = NULL;
static void *g_ptrLimitDmg = NULL;
static uint32_t g_orig1[2] = {0};
static uint32_t g_orig2[2] = {0};

static UIView *g_panel = nil;
static UIButton *g_btnCD = nil;
static UIButton *g_btnEnergy = nil;
static UISlider *g_slider = nil;
static UILabel *g_sliderLabel = nil;
static BOOL g_panelOpen = NO;

static kern_return_t patchMem(void *addr, const void *data, size_t sz) {
    if (!addr) return KERN_INVALID_ADDRESS;
    vm_address_t pg = (vm_address_t)addr & ~(vm_page_size - 1);
    kern_return_t kr = vm_protect(mach_task_self(), pg, vm_page_size * 2, 0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) kr = vm_protect(mach_task_self(), pg, vm_page_size, 0, VM_PROT_ALL);
    if (kr != KERN_SUCCESS) return kr;
    memcpy(addr, data, sz);
    sys_icache_invalidate(addr, sz);
    vm_protect(mach_task_self(), pg, vm_page_size, 0, VM_PROT_READ | VM_PROT_EXECUTE);
    return KERN_SUCCESS;
}

/* IL2CPP运行时查找 */
typedef void* (*il2cpp_class_from_name_t)(const char*, const char*);
typedef void* (*il2cpp_class_get_methods_t)(void*, void**);
typedef const char* (*il2cpp_method_get_name_t)(void*);
typedef void* (*il2cpp_method_get_pointer_t)(void*);
typedef void* (*il2cpp_domain_get_t)(void);
typedef void** (*il2cpp_domain_get_assemblies_t)(void*, size_t*);
typedef void* (*il2cpp_assembly_get_image_t)(void*);
typedef size_t (*il2cpp_image_get_class_count_t)(void*);
typedef void* (*il2cpp_image_get_class_t)(void*, size_t);

static void findIL2CPP(void) {
    jlog(@"=== IL2CPP Runtime Search ===");
    
    void *h = dlopen(NULL, RTLD_LAZY);
    
    /* 列出所有il2cpp导出 */
    il2cpp_domain_get_t domain_get = dlsym(h, "il2cpp_domain_get");
    il2cpp_domain_get_assemblies_t get_assemblies = dlsym(h, "il2cpp_domain_get_assemblies");
    il2cpp_assembly_get_image_t get_image = dlsym(h, "il2cpp_assembly_get_image");
    il2cpp_image_get_class_count_t class_count = dlsym(h, "il2cpp_image_get_class_count");
    il2cpp_image_get_class_t get_class = dlsym(h, "il2cpp_image_get_class");
    il2cpp_class_get_methods_t get_methods = dlsym(h, "il2cpp_class_get_methods");
    il2cpp_method_get_name_t method_name = dlsym(h, "il2cpp_method_get_name");
    il2cpp_method_get_pointer_t method_ptr = dlsym(h, "il2cpp_runtime_method_get_pointer");
    if (!method_ptr) method_ptr = dlsym(h, "il2cpp_method_get_pointer");
    
    jlog(@"APIs: domain=%p assemblies=%p image=%p class_count=%p get_class=%p get_methods=%p method_name=%p method_ptr=%p",
         domain_get, get_assemblies, get_image, class_count, get_class, get_methods, method_name, method_ptr);
    
    if (!domain_get || !get_assemblies || !get_image || !class_count || !get_class || !get_methods || !method_name || !method_ptr) {
        jlog(@"Missing IL2CPP APIs!");
        return;
    }
    
    void *domain = domain_get();
    jlog(@"domain=%p", domain);
    
    size_t assemblyCount = 0;
    void **assemblies = get_assemblies(domain, &assemblyCount);
    jlog(@"%zu assemblies", assemblyCount);
    
    /* 遍历所有assembly找FrameSync.code.dll */
    for (size_t a = 0; a < assemblyCount; a++) {
        void *image = get_image(assemblies[a]);
        size_t cnt = class_count(image);
        
        for (size_t c = 0; c < cnt; c++) {
            void *klass = get_class(image, c);
            if (!klass) continue;
            
            void *iter = NULL;
            void *method = NULL;
            while ((method = get_methods(klass, &iter)) != NULL) {
                const char *name = method_name(method);
                if (!name) continue;
                
                if (strcmp(name, "CheckSkillAttackCanUse") == 0) {
                    g_ptrCanUse = method_ptr(method);
                    jlog(@"FOUND CheckSkillAttackCanUse: %p", g_ptrCanUse);
                }
                if (strcmp(name, "CheckSkillIsReady") == 0) {
                    g_ptrIsReady = method_ptr(method);
                    jlog(@"FOUND CheckSkillIsReady: %p", g_ptrIsReady);
                }
                if (strcmp(name, "get_limitDamage") == 0) {
                    g_ptrLimitDmg = method_ptr(method);
                    jlog(@"FOUND get_limitDamage: %p", g_ptrLimitDmg);
                }
            }
        }
    }
    
    jlog(@"Result: CanUse=%p IsReady=%p LimitDmg=%p", g_ptrCanUse, g_ptrIsReady, g_ptrLimitDmg);
}

static void applyPatches(void) {
    findIL2CPP();
    
    if (g_ptrCanUse) {
        uint32_t v[2]; memcpy(v, g_ptrCanUse, 8);
        jlog(@"CanUse @%p: %08x %08x", g_ptrCanUse, v[0], v[1]);
        memcpy(g_orig1, g_ptrCanUse, 8);
    }
    if (g_ptrIsReady) {
        uint32_t v[2]; memcpy(v, g_ptrIsReady, 8);
        jlog(@"IsReady @%p: %08x %08x", g_ptrIsReady, v[0], v[1]);
        memcpy(g_orig2, g_ptrIsReady, 8);
    }
    
    uint32_t ret_true[] = { 0x52800020, 0xD65F03C0 };
    
    if (g_noCD && g_ptrCanUse) {
        kern_return_t kr = patchMem(g_ptrCanUse, ret_true, 8);
        jlog(@"NoCD kr=%d", kr);
    }
    if (g_noEnergy && g_ptrIsReady) {
        kern_return_t kr = patchMem(g_ptrIsReady, ret_true, 8);
        jlog(@"NoEnergy kr=%d", kr);
    }
}

static void patchLimitDamage(int value) {
    if (!g_ptrLimitDmg) return;
    uint32_t low = value & 0xFFFF;
    uint32_t high = (value >> 16) & 0xFFFF;
    uint32_t patch[3];
    patch[0] = 0x52800000 | (low << 5);
    patch[1] = high ? (0x72A00000 | (high << 5)) : 0xD65F03C0;
    patch[2] = 0xD65F03C0;
    kern_return_t kr = patchMem(g_ptrLimitDmg, patch, high ? 12 : 8);
    jlog(@"limitDmg->%d kr=%d", value, kr);
}

static void refreshButtons(void) {
    [g_btnCD setTitle: g_noCD ? @"✅ 无CD: 开" : @"❌ 无CD: 关" forState:UIControlStateNormal];
    g_btnCD.backgroundColor = g_noCD ? [UIColor colorWithRed:0.15 green:0.75 blue:0.15 alpha:0.95] : [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:0.95];
    [g_btnEnergy setTitle: g_noEnergy ? @"✅ 无能量: 开" : @"❌ 无能量: 关" forState:UIControlStateNormal];
    g_btnEnergy.backgroundColor = g_noEnergy ? [UIColor colorWithRed:0.15 green:0.75 blue:0.15 alpha:0.95] : [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:0.95];
}

static void layoutPanel(UIView *bv) {
    if (!bv || !g_panel) return;
    CGRect bf=bv.frame, sc=[UIScreen mainScreen].bounds;
    CGFloat pw=260, ph=400;
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
- (void)onCD;
- (void)onEnergy;
- (void)sliderChanged:(UISlider *)slider;
@end
@implementation JYJHActionHandler
+ (instancetype)shared { static JYJHActionHandler *s; static dispatch_once_t o; dispatch_once(&o,^{s=[[self alloc]init];}); return s; }
- (void)onCD { g_noCD=!g_noCD; refreshButtons(); applyPatches(); }
- (void)onEnergy { g_noEnergy=!g_noEnergy; refreshButtons(); applyPatches(); }
- (void)sliderChanged:(UISlider *)s { g_damageLimit=(int)s.value; g_sliderLabel.text=[NSString stringWithFormat:@"伤害上限: %d",g_damageLimit]; patchLimitDamage(g_damageLimit); }
@end

@interface JYJHBallView : UIView { CGPoint _ts; BOOL _drag; }
@end
@implementation JYJHBallView
- (instancetype)init {
    self=[super initWithFrame:CGRectMake([UIScreen mainScreen].bounds.size.width-54,100,44,44)];
    if(self){self.backgroundColor=[UIColor colorWithRed:0.1 green:0.5 blue:0.95 alpha:0.9];self.layer.cornerRadius=22;self.userInteractionEnabled=YES;
    UILabel*l=[[UILabel alloc]initWithFrame:CGRectMake(0,0,44,44)];l.text=@"剑";l.textColor=[UIColor whiteColor];l.font=[UIFont boldSystemFontOfSize:18];l.textAlignment=NSTextAlignmentCenter;[self addSubview:l];}
    return self;
}
- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent*)e{return CGRectContainsPoint(CGRectInset(self.bounds,-8,-8),p);}
- (void)touchesBegan:(NSSet*)t withEvent:(UIEvent*)e{_ts=[[t anyObject]locationInView:self.superview];_drag=NO;}
- (void)touchesMoved:(NSSet*)t withEvent:(UIEvent*)e{CGPoint c=[[t anyObject]locationInView:self.superview];CGFloat dx=c.x-_ts.x,dy=c.y-_ts.y;if(fabs(dx)>5||fabs(dy)>5){_drag=YES;CGRect f=self.frame;CGRect sc=[UIScreen mainScreen].bounds;f.origin.x=MAX(0,MIN(sc.size.width-f.size.width,f.origin.x+dx));f.origin.y=MAX(50,MIN(sc.size.height-f.size.height-50,f.origin.y+dy));self.frame=f;_ts=c;if(g_panelOpen)layoutPanel(self);}}
- (void)touchesEnded:(NSSet*)t withEvent:(UIEvent*)e{if(!_drag)togglePanel(self);_drag=NO;}
- (void)touchesCancelled:(NSSet*)t withEvent:(UIEvent*)e{_drag=NO;}
@end

static void setupUI(void) {
    UIWindow *win = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) if (w.isKeyWindow && !w.isHidden) { win = w; break; }
    if (!win) for (UIWindow *w in [UIApplication sharedApplication].windows) if (!w.isHidden) { win = w; break; }
    if (!win) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{setupUI();}); return; }
    
    JYJHBallView *ball = [[JYJHBallView alloc] init];
    [win addSubview:ball];
    
    g_panel=[[UIView alloc]initWithFrame:CGRectMake(0,0,260,400)];
    g_panel.backgroundColor=[UIColor colorWithRed:0.08 green:0.08 blue:0.12 alpha:0.98];
    g_panel.layer.cornerRadius=14; g_panel.hidden=YES;
    [win addSubview:g_panel];
    
    UILabel *title=[[UILabel alloc]initWithFrame:CGRectMake(0,10,260,24)];
    title.text=@"剑影江湖 v7.0"; title.textColor=[UIColor cyanColor];
    title.font=[UIFont boldSystemFontOfSize:15]; title.textAlignment=NSTextAlignmentCenter;
    [g_panel addSubview:title];
    
    g_btnCD=[UIButton buttonWithType:UIButtonTypeCustom]; g_btnCD.frame=CGRectMake(16,42,228,36);
    g_btnCD.layer.cornerRadius=8;
    [g_btnCD addTarget:[JYJHActionHandler shared] action:@selector(onCD) forControlEvents:UIControlEventTouchUpInside];
    [g_panel addSubview:g_btnCD];
    
    g_btnEnergy=[UIButton buttonWithType:UIButtonTypeCustom]; g_btnEnergy.frame=CGRectMake(16,84,228,36);
    g_btnEnergy.layer.cornerRadius=8;
    [g_btnEnergy addTarget:[JYJHActionHandler shared] action:@selector(onEnergy) forControlEvents:UIControlEventTouchUpInside];
    [g_panel addSubview:g_btnEnergy];
    
    g_sliderLabel=[[UILabel alloc]initWithFrame:CGRectMake(16,128,228,20)];
    g_sliderLabel.text=@"伤害上限: 10000"; g_sliderLabel.textColor=[UIColor whiteColor];
    g_sliderLabel.font=[UIFont systemFontOfSize:13]; [g_panel addSubview:g_sliderLabel];
    
    g_slider=[[UISlider alloc]initWithFrame:CGRectMake(16,150,228,28)];
    g_slider.minimumValue=100; g_slider.maximumValue=10000; g_slider.value=10000;
    [g_slider addTarget:[JYJHActionHandler shared] action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [g_panel addSubview:g_slider];
    
    g_debugLabel=[[UILabel alloc]initWithFrame:CGRectMake(8,186,244,204)];
    g_debugLabel.textColor=[UIColor colorWithRed:0.2 green:1.0 blue:0.2 alpha:1.0];
    g_debugLabel.font=[UIFont fontWithName:@"Menlo" size:10];
    g_debugLabel.numberOfLines=0;
    [g_panel addSubview:g_debugLabel];
    
    refreshButtons();
}

__attribute__((constructor))
static void initialize(void) {
    g_debugLines=[NSMutableArray new];
    jlog(@"========== JYJH v7.0 ==========");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(5.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        applyPatches();
        patchLimitDamage(g_damageLimit);
        setupUI();
    });
}
