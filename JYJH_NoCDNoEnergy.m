/**
 * 剑影江湖 v1.10.1 - v5.3
 * 大面板 + 调试信息清晰 + 日志写到游戏沙盒
 */

#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <dispatch/dispatch.h>
#import <UIKit/UIKit.h>
#import <stdio.h>
#import <string.h>

extern void sys_icache_invalidate(void *start, size_t len);

static FILE *g_logFile = NULL;
static NSMutableArray *g_debugLines = nil;
static UILabel *g_debugLabel = nil;

static void jlog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void jlog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[JYJH] %@", msg);
    
    if (g_debugLines) {
        [g_debugLines addObject:msg];
        if (g_debugLines.count > 30) [g_debugLines removeObjectAtIndex:0];
    }
    if (g_debugLabel) {
        g_debugLabel.text = [g_debugLines componentsJoinedByString:@"\n"];
    }
    
    if (!g_logFile) {
        /* 写到游戏沙盒Documents目录 */
        NSString *home = NSHomeDirectory();
        NSString *logPath = [home stringByAppendingPathComponent:@"Documents/jyjh.log"];
        g_logFile = fopen([logPath UTF8String], "a");
        if (g_logFile) NSLog(@"[JYJH] log: %@", logPath);
        
        if (!g_logFile) {
            /* 备选：dylib所在目录 */
            const char *dylib = _dyld_get_image_name(_dyld_image_count() - 1);
            if (dylib) {
                char path[512];
                snprintf(path, sizeof(path), "%s", dylib);
                char *slash = strrchr(path, '/');
                if (slash) { strcpy(slash+1, "jyjh.log"); g_logFile = fopen(path, "a"); }
            }
        }
        if (!g_logFile) g_logFile = fopen("/tmp/jyjh.log", "a");
    }
    if (g_logFile) { fprintf(g_logFile, "%s\n", [msg UTF8String]); fflush(g_logFile); }
}

/* v1.10.1 偏移 */
static const uint64_t OFF_CheckSkillAttackCanUse = 0x30741B8;
static const uint64_t OFF_CheckSkillIsReady       = 0x3074B54;
static const uint64_t OFF_get_limitDamage         = 0x30A2F70;
static const uint32_t ARM64_MOV_W0_1 = 0x52800020;
static const uint32_t ARM64_RET      = 0xD65F03C0;

static uint64_t g_base = 0;
static BOOL g_noCD = YES;
static BOOL g_noEnergy = YES;
static int g_damageLimit = 10000;
static uint32_t g_orig1[2] = {0, 0};
static uint32_t g_orig2[2] = {0, 0};

static UIView *g_panel = nil;
static UIButton *g_btnCD = nil;
static UIButton *g_btnEnergy = nil;
static UISlider *g_slider = nil;
static UILabel *g_sliderLabel = nil;
static BOOL g_panelOpen = NO;

/* ====== 内存补丁 ====== */
static kern_return_t patchMem(void *addr, const void *data, size_t sz) {
    vm_address_t pg = (vm_address_t)addr & ~(vm_page_size - 1);
    kern_return_t kr = vm_protect(mach_task_self(), pg, vm_page_size * 2, 0,
                                   VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS)
        kr = vm_protect(mach_task_self(), pg, vm_page_size, 0, VM_PROT_ALL);
    if (kr != KERN_SUCCESS) { jlog(@"vm_protect FAIL kr=%d", kr); return kr; }
    memcpy(addr, data, sz);
    sys_icache_invalidate(addr, sz);
    vm_protect(mach_task_self(), pg, vm_page_size, 0, VM_PROT_READ | VM_PROT_EXECUTE);
    return KERN_SUCCESS;
}

static uint64_t findBase(void) {
    uint32_t cnt = _dyld_image_count();
    jlog(@"%u modules loaded", cnt);
    
    /* 列出所有非系统模块 */
    for (uint32_t i = 0; i < cnt && i < 60; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && !strstr(name, "/usr/lib/") && !strstr(name, "/System/")) {
            uint64_t h = (uint64_t)_dyld_get_image_header(i);
            jlog(@"[%u] 0x%llx %s", i, h, name);
        }
    }
    
    /* image[0] = 主可执行文件 */
    uint64_t base0 = (uint64_t)_dyld_get_image_header(0);
    jlog(@"main exec base=0x%llx", base0);
    
    /* 验证偏移处是否有有效指令 */
    uint32_t test[2];
    memcpy(test, (void *)(base0 + OFF_CheckSkillAttackCanUse), 8);
    jlog(@"base+0x30741B8: %08x %08x", test[0], test[1]);
    
    if (test[0] == 0 || test[0] == 0xFFFFFFFF) {
        jlog(@"base[0] INVALID, searching...");
        for (uint32_t i = 1; i < cnt; i++) {
            uint64_t h = (uint64_t)_dyld_get_image_header(i);
            if (h < 0x100000000) continue; /* 跳过太小的地址 */
            memcpy(test, (void *)(h + OFF_CheckSkillAttackCanUse), 8);
            if (test[0] != 0 && test[0] != 0xFFFFFFFF) {
                jlog(@"FOUND [%u] 0x%llx: %08x %08x", i, h, test[0], test[1]);
                return h;
            }
        }
        jlog(@"NO valid base found!");
    }
    
    return base0;
}

static void applyPatches(void) {
    if (!g_base) {
        g_base = findBase();
        jlog(@"Using base=0x%llx", g_base);
        
        void *p1 = (void *)(g_base + OFF_CheckSkillAttackCanUse);
        void *p2 = (void *)(g_base + OFF_CheckSkillIsReady);
        uint32_t v1[2], v2[2];
        memcpy(v1, p1, 8); memcpy(v2, p2, 8);
        jlog(@"CanUse @%p: %08x %08x", p1, v1[0], v1[1]);
        jlog(@"IsReady @%p: %08x %08x", p2, v2[0], v2[1]);
        
        memcpy(g_orig1, p1, 8); memcpy(g_orig2, p2, 8);
    }
    
    uint32_t p[] = { ARM64_MOV_W0_1, ARM64_RET };
    kern_return_t kr1 = g_noCD ? patchMem((void*)(g_base+OFF_CheckSkillAttackCanUse),p,8) : (patchMem((void*)(g_base+OFF_CheckSkillAttackCanUse),g_orig1,8), KERN_SUCCESS);
    kern_return_t kr2 = g_noEnergy ? patchMem((void*)(g_base+OFF_CheckSkillIsReady),p,8) : (patchMem((void*)(g_base+OFF_CheckSkillIsReady),g_orig2,8), KERN_SUCCESS);
    jlog(@"Patch CD=%d kr=%d E=%d kr=%d", g_noCD, kr1, g_noEnergy, kr2);
}

static void patchLimitDamage(int value) {
    if (!g_base) return;
    void *addr = (void *)(g_base + OFF_get_limitDamage);
    uint32_t low = value & 0xFFFF;
    uint32_t high = (value >> 16) & 0xFFFF;
    uint32_t patch[3];
    patch[0] = 0x52800000 | (low << 5);
    patch[1] = high ? (0x72A00000 | (high << 5)) : ARM64_RET;
    patch[2] = ARM64_RET;
    kern_return_t kr = patchMem(addr, patch, high ? 12 : 8);
    jlog(@"limitDmg->%d: %s", value, kr==KERN_SUCCESS?"OK":"FAIL");
}

/* ====== UI ====== */
static void refreshButtons(void) {
    [g_btnCD setTitle: g_noCD ? @"✅ 无CD: 开" : @"❌ 无CD: 关" forState:UIControlStateNormal];
    g_btnCD.backgroundColor = g_noCD ? [UIColor colorWithRed:0.15 green:0.75 blue:0.15 alpha:0.95] : [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:0.95];
    [g_btnEnergy setTitle: g_noEnergy ? @"✅ 无能量: 开" : @"❌ 无能量: 关" forState:UIControlStateNormal];
    g_btnEnergy.backgroundColor = g_noEnergy ? [UIColor colorWithRed:0.15 green:0.75 blue:0.15 alpha:0.95] : [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:0.95];
}

static void layoutPanel(UIView *bv) {
    if (!bv || !g_panel) return;
    CGRect bf = bv.frame, sc = [UIScreen mainScreen].bounds;
    CGFloat pw = 260, ph = 400;
    CGFloat px = bf.origin.x - pw - 8;
    if (px < 4) px = bf.origin.x + bf.size.width + 8;
    CGFloat py = bf.origin.y + bf.size.height/2 - ph/2;
    if (py < 4) py = 4;
    if (py + ph > sc.size.height - 4) py = sc.size.height - ph - 4;
    g_panel.frame = CGRectMake(px, py, pw, ph);
}

static void togglePanel(UIView *bv) {
    g_panelOpen = !g_panelOpen;
    g_panel.hidden = !g_panelOpen;
    if (g_panelOpen) layoutPanel(bv);
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

/* ====== 悬浮球 ====== */
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

/* ====== 初始化 ====== */
static void setupUI(void) {
    UIWindow *win = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows)
        if (w.isKeyWindow && !w.isHidden) { win = w; break; }
    if (!win)
        for (UIWindow *w in [UIApplication sharedApplication].windows)
            if (!w.isHidden) { win = w; break; }
    if (!win) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{setupUI();}); return; }
    
    JYJHBallView *ball = [[JYJHBallView alloc] init];
    [win addSubview:ball];
    
    /* 大面板 260x400 */
    g_panel = [[UIView alloc] initWithFrame:CGRectMake(0,0,260,400)];
    g_panel.backgroundColor = [UIColor colorWithRed:0.08 green:0.08 blue:0.12 alpha:0.98];
    g_panel.layer.cornerRadius = 14;
    g_panel.hidden = YES;
    [win addSubview:g_panel];
    
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0,10,260,24)];
    title.text = @"剑影江湖 v5.3 调试版"; title.textColor = [UIColor cyanColor];
    title.font = [UIFont boldSystemFontOfSize:15]; title.textAlignment = NSTextAlignmentCenter;
    [g_panel addSubview:title];
    
    g_btnCD = [UIButton buttonWithType:UIButtonTypeCustom]; g_btnCD.frame=CGRectMake(16,42,228,36);
    g_btnCD.layer.cornerRadius=8;
    [g_btnCD addTarget:[JYJHActionHandler shared] action:@selector(onCD) forControlEvents:UIControlEventTouchUpInside];
    [g_panel addSubview:g_btnCD];
    
    g_btnEnergy = [UIButton buttonWithType:UIButtonTypeCustom]; g_btnEnergy.frame=CGRectMake(16,84,228,36);
    g_btnEnergy.layer.cornerRadius=8;
    [g_btnEnergy addTarget:[JYJHActionHandler shared] action:@selector(onEnergy) forControlEvents:UIControlEventTouchUpInside];
    [g_panel addSubview:g_btnEnergy];
    
    g_sliderLabel = [[UILabel alloc] initWithFrame:CGRectMake(16,128,228,20)];
    g_sliderLabel.text=@"伤害上限: 10000"; g_sliderLabel.textColor=[UIColor whiteColor];
    g_sliderLabel.font=[UIFont systemFontOfSize:13]; [g_panel addSubview:g_sliderLabel];
    
    g_slider = [[UISlider alloc] initWithFrame:CGRectMake(16,150,228,28)];
    g_slider.minimumValue=100; g_slider.maximumValue=10000; g_slider.value=10000;
    [g_slider addTarget:[JYJHActionHandler shared] action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [g_panel addSubview:g_slider];
    
    /* 大调试区域 - 占面板下半部分 */
    g_debugLabel = [[UILabel alloc] initWithFrame:CGRectMake(8,186,244,204)];
    g_debugLabel.textColor = [UIColor colorWithRed:0.2 green:1.0 blue:0.2 alpha:1.0];
    g_debugLabel.font = [UIFont fontWithName:@"Menlo" size:10];
    g_debugLabel.numberOfLines = 0;
    g_debugLabel.lineBreakMode = NSLineBreakByCharWrapping;
    [g_panel addSubview:g_debugLabel];
    
    refreshButtons();
}

__attribute__((constructor))
static void initialize(void) {
    g_debugLines = [NSMutableArray new];
    jlog(@"========== JYJH v5.3 ==========");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        applyPatches();
        patchLimitDamage(g_damageLimit);
        setupUI();
    });
}
