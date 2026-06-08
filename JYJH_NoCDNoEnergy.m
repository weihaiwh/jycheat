/**
 * 剑影江湖 v1.10.1 - v5.2
 * 日志写到多路径 + 悬浮球显示调试信息
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

static void jlog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void jlog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[JYJH] %@", msg);
    
    if (g_debugLines) {
        [g_debugLines addObject:msg];
        if (g_debugLines.count > 20) [g_debugLines removeObjectAtIndex:0];
    }
    
    /* 尝试多个路径写日志 */
    if (!g_logFile) {
        const char *paths[] = {
            "/var/mobile/Library/Caches/jyjh.log",
            "/var/jb/tmp/jyjh.log",
            "/tmp/jyjh.log",
            "/var/mobile/Documents/jyjh.log",
            NULL
        };
        for (int i = 0; paths[i]; i++) {
            g_logFile = fopen(paths[i], "a");
            if (g_logFile) { NSLog(@"[JYJH] log file opened: %s", paths[i]); break; }
        }
    }
    if (g_logFile) {
        fprintf(g_logFile, "%s\n", [msg UTF8String]);
        fflush(g_logFile);
    }
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
static BOOL g_patchOK = NO;

static UIView *g_panel = nil;
static UIButton *g_btnCD = nil;
static UIButton *g_btnEnergy = nil;
static UISlider *g_slider = nil;
static UILabel *g_sliderLabel = nil;
static UILabel *g_debugLabel = nil;
static BOOL g_panelOpen = NO;

/* ====== 内存补丁 ====== */
static kern_return_t patchMem(void *addr, const void *data, size_t sz) {
    vm_address_t pg = (vm_address_t)addr & ~(vm_page_size - 1);
    kern_return_t kr = vm_protect(mach_task_self(), pg, vm_page_size * 2, 0,
                                   VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS)
        kr = vm_protect(mach_task_self(), pg, vm_page_size, 0, VM_PROT_ALL);
    if (kr != KERN_SUCCESS) { jlog(@"vm_protect FAIL kr=%d addr=%p", kr, addr); return kr; }
    memcpy(addr, data, sz);
    sys_icache_invalidate(addr, sz);
    vm_protect(mach_task_self(), pg, vm_page_size, 0, VM_PROT_READ | VM_PROT_EXECUTE);
    return KERN_SUCCESS;
}

static uint64_t findBase(void) {
    uint32_t cnt = _dyld_image_count();
    jlog(@"=== %u modules ===", cnt);
    
    for (uint32_t i = 0; i < cnt && i < 50; i++) {
        const char *name = _dyld_get_image_name(i);
        uint64_t h = (uint64_t)_dyld_get_image_header(i);
        if (name && !strstr(name, "/usr/lib/") && !strstr(name, "/System/")) {
            jlog(@"[%u] %s 0x%llx", i, name, h);
        }
    }
    
    /* image[0] = main executable */
    return (uint64_t)_dyld_get_image_header(0);
}

static void applyPatches(void) {
    if (!g_base) {
        g_base = findBase();
        jlog(@"base=0x%llx", g_base);
        
        /* 读原始指令 */
        void *p1 = (void *)(g_base + OFF_CheckSkillAttackCanUse);
        void *p2 = (void *)(g_base + OFF_CheckSkillIsReady);
        uint32_t v1[2], v2[2];
        memcpy(v1, p1, 8);
        memcpy(v2, p2, 8);
        jlog(@"@0x%llx: %08x %08x", g_base + OFF_CheckSkillAttackCanUse, v1[0], v1[1]);
        jlog(@"@0x%llx: %08x %08x", g_base + OFF_CheckSkillIsReady, v2[0], v2[1]);
        
        /* 验证：合理的ARM64指令不应是全0或全F */
        BOOL valid1 = (v1[0] != 0 && v1[0] != 0xFFFFFFFF);
        BOOL valid2 = (v2[0] != 0 && v2[0] != 0xFFFFFFFF);
        jlog(@"Valid: func1=%d func2=%d", valid1, valid2);
        
        if (!valid1 || !valid2) {
            jlog(@"WARNING: bytes look invalid, base may be wrong!");
            /* 尝试搜索正确的模块 */
            for (uint32_t i = 0; i < _dyld_image_count(); i++) {
                const char *name = _dyld_get_image_name(i);
                uint64_t h = (uint64_t)_dyld_get_image_header(i);
                if (h == 0 || h == g_base) continue;
                uint32_t test[2];
                memcpy(test, (void *)(h + OFF_CheckSkillAttackCanUse), 8);
                if (test[0] != 0 && test[0] != 0xFFFFFFFF) {
                    jlog(@"FOUND valid at [%u] %s base=0x%llx: %08x %08x", i, name ? name : "?", h, test[0], test[1]);
                    g_base = h;
                    memcpy(v1, (void *)(g_base + OFF_CheckSkillAttackCanUse), 8);
                    memcpy(v2, (void *)(g_base + OFF_CheckSkillIsReady), 8);
                    jlog(@"Switched to base=0x%llx", g_base);
                    break;
                }
            }
        }
        
        memcpy(g_orig1, (void *)(g_base + OFF_CheckSkillAttackCanUse), 8);
        memcpy(g_orig2, (void *)(g_base + OFF_CheckSkillIsReady), 8);
    }
    
    uint32_t p[] = { ARM64_MOV_W0_1, ARM64_RET };
    kern_return_t kr1 = KERN_SUCCESS, kr2 = KERN_SUCCESS;
    
    if (g_noCD) kr1 = patchMem((void *)(g_base + OFF_CheckSkillAttackCanUse), p, 8);
    else if (g_orig1[0]) patchMem((void *)(g_base + OFF_CheckSkillAttackCanUse), g_orig1, 8);
    
    if (g_noEnergy) kr2 = patchMem((void *)(g_base + OFF_CheckSkillIsReady), p, 8);
    else if (g_orig2[0]) patchMem((void *)(g_base + OFF_CheckSkillIsReady), g_orig2, 8);
    
    g_patchOK = (kr1 == KERN_SUCCESS && kr2 == KERN_SUCCESS);
    jlog(@"Patch: CD=%d kr=%d | Energy=%d kr=%d", g_noCD, kr1, g_noEnergy, kr2);
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
    size_t sz = high ? 12 : 8;
    kern_return_t kr = patchMem(addr, patch, sz);
    jlog(@"limitDamage->%d: %s", value, kr == KERN_SUCCESS ? "OK" : "FAIL");
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
    CGFloat pw = 200, ph = 250;
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
    if (g_panelOpen) {
        layoutPanel(bv);
        /* 更新调试信息 */
        if (g_debugLabel && g_debugLines) {
            g_debugLabel.text = [g_debugLines componentsJoinedByString:@"\n"];
        }
    }
}

static void updateDebugOnBall(NSString *text) {
    /* 在悬浮球旁边显示状态 */
}

@interface JYJHActionHandler : NSObject
+ (instancetype)shared;
- (void)onCD;
- (void)onEnergy;
- (void)sliderChanged:(UISlider *)slider;
@end

@implementation JYJHActionHandler
+ (instancetype)shared {
    static JYJHActionHandler *s = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ s = [[self alloc] init]; });
    return s;
}
- (void)onCD { g_noCD = !g_noCD; refreshButtons(); applyPatches(); }
- (void)onEnergy { g_noEnergy = !g_noEnergy; refreshButtons(); applyPatches(); }
- (void)sliderChanged:(UISlider *)slider {
    g_damageLimit = (int)slider.value;
    g_sliderLabel.text = [NSString stringWithFormat:@"伤害上限: %d", g_damageLimit];
    patchLimitDamage(g_damageLimit);
}
@end

/* ====== 悬浮球 ====== */
@interface JYJHBallView : UIView { CGPoint _ts; BOOL _drag; }
@end
@implementation JYJHBallView
- (instancetype)init {
    self = [super initWithFrame:CGRectMake([UIScreen mainScreen].bounds.size.width - 54, 100, 44, 44)];
    if (self) {
        self.backgroundColor = [UIColor colorWithRed:0.1 green:0.5 blue:0.95 alpha:0.9];
        self.layer.cornerRadius = 22;
        self.userInteractionEnabled = YES;
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(0,0,44,44)];
        l.text = @"剑"; l.textColor = [UIColor whiteColor];
        l.font = [UIFont boldSystemFontOfSize:18]; l.textAlignment = NSTextAlignmentCenter;
        [self addSubview:l];
    }
    return self;
}
- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent *)e { return CGRectContainsPoint(CGRectInset(self.bounds,-8,-8),p); }
- (void)touchesBegan:(NSSet *)t withEvent:(UIEvent *)e { _ts=[[t anyObject] locationInView:self.superview]; _drag=NO; }
- (void)touchesMoved:(NSSet *)t withEvent:(UIEvent *)e {
    CGPoint c=[[t anyObject] locationInView:self.superview]; CGFloat dx=c.x-_ts.x,dy=c.y-_ts.y;
    if(fabs(dx)>5||fabs(dy)>5){_drag=YES;CGRect f=self.frame;CGRect sc=[UIScreen mainScreen].bounds;
    f.origin.x=MAX(0,MIN(sc.size.width-f.size.width,f.origin.x+dx));
    f.origin.y=MAX(50,MIN(sc.size.height-f.size.height-50,f.origin.y+dy));
    self.frame=f;_ts=c;if(g_panelOpen)layoutPanel(self);}
}
- (void)touchesEnded:(NSSet *)t withEvent:(UIEvent *)e { if(!_drag)togglePanel(self);_drag=NO; }
- (void)touchesCancelled:(NSSet *)t withEvent:(UIEvent *)e { _drag=NO; }
@end

/* ====== 初始化 ====== */
static void setupUI(void) {
    UIWindow *win = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows)
        if (w.isKeyWindow && !w.isHidden) { win = w; break; }
    if (!win)
        for (UIWindow *w in [UIApplication sharedApplication].windows)
            if (!w.isHidden) { win = w; break; }
    if (!win) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{setupUI();});
        return;
    }
    
    JYJHBallView *ball = [[JYJHBallView alloc] init];
    [win addSubview:ball];
    
    g_panel = [[UIView alloc] initWithFrame:CGRectMake(0,0,200,250)];
    g_panel.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.15 alpha:0.97];
    g_panel.layer.cornerRadius = 14;
    g_panel.hidden = YES;
    [win addSubview:g_panel];
    
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0,8,200,22)];
    title.text = @"剑影江湖 v5.2"; title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:14]; title.textAlignment = NSTextAlignmentCenter;
    [g_panel addSubview:title];
    
    g_btnCD = [UIButton buttonWithType:UIButtonTypeCustom]; g_btnCD.frame=CGRectMake(12,34,176,32);
    g_btnCD.layer.cornerRadius=8;
    [g_btnCD addTarget:[JYJHActionHandler shared] action:@selector(onCD) forControlEvents:UIControlEventTouchUpInside];
    [g_panel addSubview:g_btnCD];
    
    g_btnEnergy = [UIButton buttonWithType:UIButtonTypeCustom]; g_btnEnergy.frame=CGRectMake(12,70,176,32);
    g_btnEnergy.layer.cornerRadius=8;
    [g_btnEnergy addTarget:[JYJHActionHandler shared] action:@selector(onEnergy) forControlEvents:UIControlEventTouchUpInside];
    [g_panel addSubview:g_btnEnergy];
    
    g_sliderLabel = [[UILabel alloc] initWithFrame:CGRectMake(12,108,176,18)];
    g_sliderLabel.text=@"伤害上限: 10000"; g_sliderLabel.textColor=[UIColor whiteColor];
    g_sliderLabel.font=[UIFont systemFontOfSize:11]; [g_panel addSubview:g_sliderLabel];
    
    g_slider = [[UISlider alloc] initWithFrame:CGRectMake(12,126,176,28)];
    g_slider.minimumValue=100; g_slider.maximumValue=10000; g_slider.value=10000;
    [g_slider addTarget:[JYJHActionHandler shared] action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [g_panel addSubview:g_slider];
    
    /* 调试信息区域 */
    g_debugLabel = [[UILabel alloc] initWithFrame:CGRectMake(8,158,184,86)];
    g_debugLabel.textColor = [UIColor greenColor];
    g_debugLabel.font = [UIFont fontWithName:@"Menlo" size:8];
    g_debugLabel.numberOfLines = 0;
    g_debugLabel.adjustsFontSizeToFitWidth = NO;
    [g_panel addSubview:g_debugLabel];
    
    refreshButtons();
}

__attribute__((constructor))
static void initialize(void) {
    g_debugLines = [NSMutableArray new];
    jlog(@"========== JYJH v5.2 ==========");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        applyPatches();
        patchLimitDamage(g_damageLimit);
        setupUI();
    });
}
