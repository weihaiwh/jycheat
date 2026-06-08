/**
 * 剑影江湖 v1.10.1 - 无CD无能量+伤害修改 v5.1
 * TrollFools注入版（无代码签名）
 * 修复：主可执行文件基址 + 日志文件 + 伤害修改
 */

#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <dispatch/dispatch.h>
#import <UIKit/UIKit.h>
#import <stdio.h>
#import <string.h>

extern void sys_icache_invalidate(void *start, size_t len);

static FILE *g_logFile = NULL;
static void jlog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void jlog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[JYJH] %@", msg);
    if (!g_logFile) {
        g_logFile = fopen("/var/mobile/Library/Caches/jyjh.log", "a");
        if (!g_logFile) g_logFile = fopen("/tmp/jyjh.log", "a");
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

static UIView *g_panel = nil;
static UIButton *g_btnCD = nil;
static UIButton *g_btnEnergy = nil;
static UISlider *g_slider = nil;
static UILabel *g_sliderLabel = nil;
static BOOL g_panelOpen = NO;

/* ====== 内存补丁 ====== */
static kern_return_t patchMem(void *addr, const void *data, size_t sz) {
    vm_address_t pg = (vm_address_t)addr & ~(vm_page_size - 1);
    kern_return_t kr = vm_protect(mach_task_self(), pg, vm_page_size, 0,
                                   VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS)
        kr = vm_protect(mach_task_self(), pg, vm_page_size, 0, VM_PROT_ALL);
    if (kr != KERN_SUCCESS) { jlog(@"vm_protect FAILED: %d", kr); return kr; }
    memcpy(addr, data, sz);
    sys_icache_invalidate(addr, sz);
    vm_protect(mach_task_self(), pg, vm_page_size, 0, VM_PROT_READ | VM_PROT_EXECUTE);
    return KERN_SUCCESS;
}

static uint64_t findBase(void) {
    uint32_t cnt = _dyld_image_count();
    jlog(@"=== %u modules loaded ===", cnt);
    
    /* 主可执行文件 = image[0] */
    const char *name0 = _dyld_get_image_name(0);
    uint64_t base0 = (uint64_t)_dyld_get_image_header(0);
    jlog(@"[0] %s base=0x%llx (main executable)", name0 ? name0 : "?", base0);
    
    /* 也列出其他可能的游戏模块 */
    for (uint32_t i = 1; i < cnt && i < 30; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && !strstr(name, "/usr/lib/") && !strstr(name, "/System/")) {
            uint64_t h = (uint64_t)_dyld_get_image_header(i);
            jlog(@"[%u] %s base=0x%llx", i, name, h);
        }
    }
    
    return base0;
}

static void applyPatches(void) {
    if (!g_base) {
        g_base = findBase();
        jlog(@"Using base=0x%llx", g_base);
        
        void *p1 = (void *)(g_base + OFF_CheckSkillAttackCanUse);
        void *p2 = (void *)(g_base + OFF_CheckSkillIsReady);
        
        /* 读取原始指令验证基址是否正确 */
        uint32_t v1[2], v2[2];
        memcpy(v1, p1, 8);
        memcpy(v2, p2, 8);
        jlog(@"Addr1=0x%llx bytes: %08x %08x", (uint64_t)p1, v1[0], v1[1]);
        jlog(@"Addr2=0x%llx bytes: %08x %08x", (uint64_t)p2, v2[0], v2[1]);
        
        /* 保存原始指令 */
        memcpy(g_orig1, p1, 8);
        memcpy(g_orig2, p2, 8);
    }
    
    uint32_t p[] = { ARM64_MOV_W0_1, ARM64_RET };
    
    if (g_noCD) {
        kern_return_t kr = patchMem((void *)(g_base + OFF_CheckSkillAttackCanUse), p, 8);
        jlog(@"Patch CheckSkillAttackCanUse: %s (kr=%d)", kr == KERN_SUCCESS ? "OK" : "FAIL", kr);
    } else if (g_orig1[0]) {
        patchMem((void *)(g_base + OFF_CheckSkillAttackCanUse), g_orig1, 8);
    }
    
    if (g_noEnergy) {
        kern_return_t kr = patchMem((void *)(g_base + OFF_CheckSkillIsReady), p, 8);
        jlog(@"Patch CheckSkillIsReady: %s (kr=%d)", kr == KERN_SUCCESS ? "OK" : "FAIL", kr);
    } else if (g_orig2[0]) {
        patchMem((void *)(g_base + OFF_CheckSkillIsReady), g_orig2, 8);
    }
}

static void patchLimitDamage(int value) {
    if (!g_base) return;
    void *addr = (void *)(g_base + OFF_get_limitDamage);
    uint32_t low = value & 0xFFFF;
    uint32_t high = (value >> 16) & 0xFFFF;
    uint32_t patch[3];
    patch[0] = 0x52800000 | (low << 5);   /* movz w0, #low */
    if (high) {
        patch[1] = 0x72A00000 | (high << 5);  /* movk w0, #high, lsl #16 */
    } else {
        patch[1] = ARM64_RET;  /* no high bits needed, just ret early */
        patch[2] = ARM64_RET;
        patchMem(addr, patch, high ? 12 : 8);
        jlog(@"Patch limitDamage -> %d: movz+ret", value);
        return;
    }
    patch[2] = ARM64_RET;
    kern_return_t kr = patchMem(addr, patch, 12);
    jlog(@"Patch limitDamage -> %d: %s (kr=%d)", value, kr == KERN_SUCCESS ? "OK" : "FAIL", kr);
}

/* ====== UI ====== */
static void refreshButtons(void) {
    [g_btnCD setTitle: g_noCD ? @"✅ 无CD: 开" : @"❌ 无CD: 关" forState:UIControlStateNormal];
    g_btnCD.backgroundColor = g_noCD ?
        [UIColor colorWithRed:0.15 green:0.75 blue:0.15 alpha:0.95] :
        [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:0.95];
    [g_btnEnergy setTitle: g_noEnergy ? @"✅ 无能量: 开" : @"❌ 无能量: 关" forState:UIControlStateNormal];
    g_btnEnergy.backgroundColor = g_noEnergy ?
        [UIColor colorWithRed:0.15 green:0.75 blue:0.15 alpha:0.95] :
        [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:0.95];
}

static void layoutPanel(UIView *ballView) {
    if (!ballView || !g_panel) return;
    CGRect bf = ballView.frame;
    CGRect sc = [UIScreen mainScreen].bounds;
    CGFloat pw = 180, ph = 200;
    CGFloat px = bf.origin.x - pw - 8;
    if (px < 4) px = bf.origin.x + bf.size.width + 8;
    CGFloat py = bf.origin.y + bf.size.height/2 - ph/2;
    if (py < 4) py = 4;
    if (py + ph > sc.size.height - 4) py = sc.size.height - ph - 4;
    g_panel.frame = CGRectMake(px, py, pw, ph);
}

static void togglePanel(UIView *ballView) {
    g_panelOpen = !g_panelOpen;
    g_panel.hidden = !g_panelOpen;
    if (g_panelOpen) layoutPanel(ballView);
}

/* ====== Action Handler ====== */
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
    int val = (int)slider.value;
    g_damageLimit = val;
    g_sliderLabel.text = [NSString stringWithFormat:@"伤害上限: %d", val];
    patchLimitDamage(val);
}
@end

/* ====== 悬浮球 ====== */
@interface JYJHBallView : UIView { CGPoint _touchStart; BOOL _isDragging; }
@end

@implementation JYJHBallView

- (instancetype)init {
    self = [super initWithFrame:CGRectMake([UIScreen mainScreen].bounds.size.width - 54, 100, 44, 44)];
    if (self) {
        self.backgroundColor = [UIColor colorWithRed:0.1 green:0.5 blue:0.95 alpha:0.9];
        self.layer.cornerRadius = 22;
        self.userInteractionEnabled = YES;
        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 44, 44)];
        lbl.text = @"剑";
        lbl.textColor = [UIColor whiteColor];
        lbl.font = [UIFont boldSystemFontOfSize:18];
        lbl.textAlignment = NSTextAlignmentCenter;
        [self addSubview:lbl];
    }
    return self;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return CGRectContainsPoint(CGRectInset(self.bounds, -8, -8), point);
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    _touchStart = [[touches anyObject] locationInView:self.superview];
    _isDragging = NO;
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    CGPoint cur = [[touches anyObject] locationInView:self.superview];
    CGFloat dx = cur.x - _touchStart.x, dy = cur.y - _touchStart.y;
    if (fabs(dx) > 5 || fabs(dy) > 5) {
        _isDragging = YES;
        CGRect f = self.frame; CGRect sc = [UIScreen mainScreen].bounds;
        f.origin.x = MAX(0, MIN(sc.size.width - f.size.width, f.origin.x + dx));
        f.origin.y = MAX(50, MIN(sc.size.height - f.size.height - 50, f.origin.y + dy));
        self.frame = f; _touchStart = cur;
        if (g_panelOpen) layoutPanel(self);
    }
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    if (!_isDragging) togglePanel(self);
    _isDragging = NO;
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event { _isDragging = NO; }

@end

/* ====== 初始化 ====== */
static void setupUI(void) {
    UIWindow *win = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow && !w.isHidden) { win = w; break; }
    }
    if (!win) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (!w.isHidden) { win = w; break; }
        }
    }
    if (!win) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ setupUI(); });
        return;
    }
    
    JYJHBallView *ball = [[JYJHBallView alloc] init];
    [win addSubview:ball];
    
    g_panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 180, 200)];
    g_panel.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.18 alpha:0.97];
    g_panel.layer.cornerRadius = 14;
    g_panel.hidden = YES;
    [win addSubview:g_panel];
    
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 8, 180, 22)];
    title.text = @"剑影江湖 v1.10.1";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:14];
    title.textAlignment = NSTextAlignmentCenter;
    [g_panel addSubview:title];
    
    g_btnCD = [UIButton buttonWithType:UIButtonTypeCustom];
    g_btnCD.frame = CGRectMake(12, 36, 156, 36);
    g_btnCD.layer.cornerRadius = 8;
    [g_btnCD addTarget:[JYJHActionHandler shared] action:@selector(onCD) forControlEvents:UIControlEventTouchUpInside];
    [g_panel addSubview:g_btnCD];
    
    g_btnEnergy = [UIButton buttonWithType:UIButtonTypeCustom];
    g_btnEnergy.frame = CGRectMake(12, 78, 156, 36);
    g_btnEnergy.layer.cornerRadius = 8;
    [g_btnEnergy addTarget:[JYJHActionHandler shared] action:@selector(onEnergy) forControlEvents:UIControlEventTouchUpInside];
    [g_panel addSubview:g_btnEnergy];
    
    g_sliderLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 122, 156, 20)];
    g_sliderLabel.text = @"伤害上限: 10000";
    g_sliderLabel.textColor = [UIColor whiteColor];
    g_sliderLabel.font = [UIFont systemFontOfSize:12];
    [g_panel addSubview:g_sliderLabel];
    
    g_slider = [[UISlider alloc] initWithFrame:CGRectMake(12, 144, 156, 30)];
    g_slider.minimumValue = 100;
    g_slider.maximumValue = 10000;
    g_slider.value = 10000;
    [g_slider addTarget:[JYJHActionHandler shared] action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [g_panel addSubview:g_slider];
    
    refreshButtons();
}

__attribute__((constructor))
static void initialize(void) {
    jlog(@"========== JYJH v5.1 loaded ==========");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        applyPatches();
        patchLimitDamage(g_damageLimit);
        setupUI();
    });
}
