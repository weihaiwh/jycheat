# 剑影江湖 (com.jyjh.whwb) 无CD无能量技能插件

## 功能

- **无CD**: 所有技能无冷却，可连续释放
- **无能量**: 大招无需能量/怒气即可释放

## 适配信息

| 项目 | 值 |
|------|-----|
| 游戏版本 | 1.8.1 |
| Bundle ID | com.jyjh.whwb |
| 系统要求 | iOS 15.0+ |
| 架构 | arm64 |
| 测试设备 | iPhone 13 Pro Max (iOS 15.6) |
| 越狱类型 | 无根越狱 (Dopamine/Palera1n) |

## 编译

项目使用 GitHub Actions 自动编译，push 到 main 分支即可触发。

也可手动触发: Actions → Build JYJH NoCD NoEnergy Dylib → Run workflow

编译产物在 Actions → Artifacts 中下载。

## 部署 (无根越狱)

```bash
# 1. 下载编译产物 JYJH_NoCDNoEnergy.dylib
# 2. SSH连接设备，拷贝到TweakInject目录

scp JYJH_NoCDNoEnergy.dylib root@<设备IP>:/var/jb/usr/lib/TweakInject/
scp JYJH_NoCDNoEnergy.plist root@<设备IP>:/var/jb/usr/lib/TweakInject/

# 3. 重启游戏
```

## 技术原理

Hook了两个IL2CPP函数:

| 函数 | 偏移 | 作用 |
|------|------|------|
| `CheckSkillAttackCanUse` | `0x2A9218` | CD/状态检测 → return true |
| `CheckSkillIsReady` | `0x2A9B08` | 能量+CD完整检测 → return true |

- `CheckSkillAttackCanUse`: 仅检查CD，hook后普通技能无CD
- `CheckSkillIsReady`: 包含能量/怒气检测，hook后大招也能释放
- 两个都hook = 所有技能/大招随意放

## 注意

- 偏移地址仅适用于 v1.8.1，游戏更新后需重新dump确认
- 帧同步游戏，技能判定为客户端逻辑，hook不影响同步
