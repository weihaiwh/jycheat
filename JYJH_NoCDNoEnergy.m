/**
 * 剑影江湖 v1.10.1 - v6.0
 * 新策略：多函数补丁
 * 1. CheckSkillAttackCanUse -> return true (技能可用检查)
 * 2. UpdateSkillCoolDown -> 空函数 (不更新CD倒计时)
 * 3. ReduceSkillCd -> 空函数 (可选，CD减少也跳过)
 * 4. get_limitDamage -> return 自定义值
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
    if (g_debugLines) { [g_debugLines addObject:msg]; if(g_debugLines.count>30)[g_debugLines removeObjectAtIndex:0]; }
    if (g_debugLabel) g_debugLabel.text = [g_debugLines componentsJoinedByString:@"\n"];
    if (!g_logFile) {
        NSString *p = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/jyjh.log"];
        g_logFile = fopen([p UTF8String], "a");
        if (!g_logFile) g_logFile = fopen("/tmp/jyjh.log", "a");
    }
    if (g_logFile) { fprintf(g_logFile, "%s\n", [msg UTF8String]); fflush(g_logFile); }
}

/* v1.10.1 偏移 */
static const uint64_t OFF_CheckSkillAttackCanUse = 0x30741B8;
static const uint64_t OFF_CheckSkillIsReady       = 0x3074B54;
static const uint64_t OFF_UpdateSkillCoolDown     = 0x30C7FA8;
static const uint64_t OFF_ReduceSkillCd           = 0x3073288;
static const uint64_t OFF_get_limitDamage         = 0x30A2F70;
static const uint64_t OFF_PlayerUseSkill          = 0x309681C;

static const uint32_t ARM64_MOV_W0_1 = 0x52800020;
static const uint32_t ARM64_RET      = 0xD65F03C0;

static uint64_t g_base = 0;
static BOOL g_noCD = YES;
static BOOL g_noEnergy = YES;
static int g_damageLimit = 10000;

/* 保存原始指令 */
static uint32_t g_origCheckCanUse[2] = {0};
static uint32_t g_origCheckIsReady[2] = {0};
static uint32_t g_origUpdateCD[4] = {0};
static uint32_t g_origReduceCD[4] = {0};
static uint32_t g_origLimitDmg[8] = {0};

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
    if (kr != KERN_SUCCESS) return kr;
    memcpy(addr, data, sz);
    sys_icache_invalidate(addr, sz);
    vm_protect(mach_task_self(), pg, vm_page_size, 0, VM_PROT_READ | VM_PROT_EXECUTE);
    return KERN_SUCCESS;
}

static uint64_t findBase(void) {
    uint32_t cnt = _dyld_image_count();
    jlog(@"%u modules", cnt);
    for (uint32_t i = 0; i < cnt && i < 60; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && !strstr(name, "/usr/lib/") && !strstr(name, "/System/")) {
            uint64_t h = (uint64_t)_dyld_get_image_header(i);
            jlog(@"[%u] 0x%llx %s", i, h, name);
        }
    }
    return (uint64_t)_dyld_get_image_header(0);
}

static void readBytes(const char *name, uint64_t addr, uint32_t *buf, int count) {
    void *p = (void *)(g_base + addr);
    memcpy(buf, p, count * 4);
    NSString *hex = [NSString stringWithFormat:@"%@ @0x%llx:", name, (uint64_t)p];
    for (int i = 0; i < count && i < 4; i++)
        hex = [hex stringByAppendingFormat:@" %08x", buf[i]];
    jlog(@"%@", hex);
}

static void applyPatches(void) {
    if (!g_base) {
        g_base = findBase();
        jlog(@"base=0x%llx", g_base);
        
        /* 读取所有目标函数的原始字节 */
        readBytes("CanUse", OFF_CheckSkillAttackCanUse, g_origCheckCanUse, 2);
        readBytes("IsReady", OFF_CheckSkillIsReady, g_origCheckIsReady, 2);
        readBytes("UpdateCD", OFF_UpdateSkillCoolDown, g_origUpdateCD, 4);
        readBytes("ReduceCD", OFF_ReduceSkillCd, g_origReduceCD, 4);
        readBytes("LimitDmg", OFF_get_limitDamage, g_origLimitDmg, 4);
    }
    
    uint32_t ret_true[] = { ARM64_MOV_W0_1, ARM64_RET };  /* return true */
    uint32_t ret_void[] = { ARM64_RET };                     /* return (void) */
    
    if (g_noCD) {
        /* CheckSkillAttackCanUse -> return true */
        kern_return_t kr1 = patchMem((void*)(g_base+OFF_CheckSkillAttackCanUse), ret_true, 8);
        /* UpdateSkillCoolDown -> return (不更新CD) */
        kern_return_t kr2 = patchMem((void*)(g_base+OFF_UpdateSkillCoolDown), ret_void, 4);
        /* ReduceSkillCd -> return (可选) */
        kern_return_t kr3 = patchMem((void*)(g_base+OFF_ReduceSkillCd), ret_void, 4);
        jlog(@"NoCD: CanUse kr=%d UpdateCD kr=%d ReduceCD kr=%d", kr1, kr2, kr3);
    } else {
        /* 恢复原始 */
        if (g_origCheckCanUse[0]) patchMem((void*)(g_base+OFF_CheckSkillAttackCanUse), g_origCheckCanUse, 8);
        if (g_origUpdateCD[0]) patchMem((void*)(g_base+OFF_UpdateSkillCoolDown), g_origUpdateCD, 16);
        if (g_origReduceCD[0]) patchMem((void*)(g_base+OFF_ReduceSkillCd), g_origReduceCD, 16);
        jlog(@"NoCD: restored");
    }
    
    if (g_noEnergy) {
        /* CheckSkillIsReady -> return true (如果原始不是已经return true) */
        kern_return_t kr = patchMem((void*)(g_base+OFF_CheckSkillIsReady), ret_true, 8);
        jlog(@"NoEnergy: IsReady kr=%d", kr);
    } else {
        if (g_origCheckIsReady[0]) patchMem((void*)(g_base+OFF_CheckSkillIsReady), g_origCheckIsReady, 8);
        jlog(@"NoEnergy: restored");
    }
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
    for (UIWindow *w in [UIApplication sharedApplication].windows)
        if (w.isKeyWindow && !w.isHidden) { win = w; break; }
    if (!win) for (UIWindow *w in [UIApplication sharedApplication].windows)
        if (!w.isHidden) { win = w; break; }
    if (!win) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{setupUI();}); return; }
    
    JYJHBallView *ball = [[JYJHBallView alloc] init];
    [win addSubview:ball];
    
    g_panel=[[UIView alloc]initWithFrame:CGRectMake(0,0,260,400)];
    g_panel.backgroundColor=[UIColor colorWithRed:0.08 green:0.08 blue:0.12 alpha:0.98];
    g_panel.layer.cornerRadius=14; g_panel.hidden=YES;
    [win addSubview:g_panel];
    
    UILabel *title=[[UILabel alloc]initWithFrame:CGRectMake(0,10,260,24)];
    title.text=@"剑影江湖 v6.0"; title.textColor=[UIColor cyanColor];
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
    g_debugLabel.numberOfLines=0; g_debugLabel.lineBreakMode=NSLineBreakByCharWrapping;
    [g_panel addSubview:g_debugLabel];
    
    refreshButtons();
}

__attribute__((constructor))
static void initialize(void) {
    g_debugLines=[NSMutableArray new];
    jlog(@"========== JYJH v6.0 ==========");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        applyPatches();
        patchLimitDamage(g_damageLimit);
        setupUI();
    });
}
