# Poiesis Liquid Glass fork

## 上游基线

- 包名：`liquid_glass_widgets`
- 官方稳定版：`1.3.0`
- 官方 tag commit：`3482b728fbab125da90f766b4f386e3707be4f3f`
- pub.dev 发布时间：2026-09-04 02:59:04 UTC
- 官方仓库：<https://github.com/sdegenaar/liquid_glass_widgets>
- Poiesis fork：<https://github.com/nano122/liquid_glass_widgets>
- 发布包 SHA-256：`f9a93694ec2c4607f5adb7140f648cda176aaf943cfbec552c5c416342f828de`

当前版本从旧 Poiesis fork 的 `main` 以 merge commit 合入官方 `v1.3.0`，再
语义迁移 Poiesis 补丁；没有压平历史或强制覆盖分支。Poiesis 主项目通过 Git
submodule 固定具体提交，补丁、Shader 和测试都在 fork 中独立版本化。

## Poiesis 补丁

1. Standard 与 Premium 在 Impeller 上共用官方完整的
   `LiquidGlassLayer`、`BackdropGroup` 和 Shader host，确保所有子玻璃从同一
   compositor backdrop 采样；Skia/Web 继续保持根层透传并使用轻量 Shader。
2. `MultiShaderBuilder` 按 key 内容比较，复用相同 `FragmentShader`，并在
   key 变化或组件销毁时释放原生 GPU 实例。
3. Standard 的 `BackdropFilterLayer` 跨帧保留，使用紧 `childPaintBounds`；
   饱和度为 1 时跳过恒等颜色矩阵。
4. Premium 几何纹理只在本地尺寸、DPR 或真实 shape geometry 变化时失效，
   重复 layout 不再触发 `Picture.toImageSync`。
5. 圆角矩形交互指示器在 Impeller 上由 Standard/Premium 共用官方 `LiquidGlassLayer` 的实时
   compositor backdrop 与最终渲染 Shader 内解析式 SDF：
   - 不再调用 `RenderRepaintBoundary.toImageSync`，透明 `GlassScaffold` 也不会
     把透明黑快照误当作有效背景；
   - 不创建第二个 `BackdropFilterLayer`；解析式与纹理式 Premium 共用官方
     单一 Shader layer、紧 clip 和 sampler 0，直接折射后方页面、图标与文字；
   - 跳过 geometry texture 的同步栅格化和上传；保留轻量路径/轮廓元数据，供
     官方形状 blur clip、child 分层和不支持时的无损回退使用；
   - 移动、拉伸和 pinch 只更新圆角尺寸与“屏幕物理像素 → shape 本地逻辑
     像素”的仿射逆变换 uniform；
   - Standard 的显式 sampler 继续使用硬件双线性，普通折射 1 次、色散边缘
     3 次读取；
   - 保留 visibility、圆角 SDF、边缘折射、pinch、Fresnel、高光和色散。
6. `blur: 0` 只关闭 Gaussian background blur Pass，不再让 `AdaptiveGlass`
   提前退化为 `_FrostedFallback`；Premium 继续执行原生折射 shader，Standard
   与不支持 ShaderFilter 的平台继续执行轻量 shader。底层 renderer 仍以
   `effectiveBlur > 0` 为创建模糊层的唯一条件，因此零值不会产生高斯模糊层。
7. Premium、Standard 与交互指示器共用 `edge_treatment.glsl` 的双层边缘：
   - 所有玻璃向外投射的 elevation / BoxShadow 统一关闭：`GlassShadow` 集中策略让
     `LiquidGlassSettings.effectiveShadow` 即使收到显式 custom shadow 也返回空列表，
     因此 Premium SDF、Standard 轻量路径、底栏阴影覆盖层和背景图 FrostedSurface
     都不会创建玻璃外投影；Shader 内部折射、边缘暗部与交互光晕不受影响；
   - 双层细边与物理 `edgeAbsorption` 解耦：先绘制完整围绕轮廓的
     `0.36 logical px`、颜色 `vec3(0.68, 0.68, 0.76)`、透明度 `0.50` 的冷灰边，再按
     `abs(normal.x)` 只在左右叠加颜色 `vec3(0.01, 0.015, 0.08)`、透明度 `0.72` 的锐利
     `0.18 logical px` 冷黑边；`edgeAbsorption=0` 仅关闭 Beer–Lambert
     弯月面变暗，不会移除这两层结构边；
   - 双层结构边内侧新增长宽比（Aspect Ratio）自适应高光：以容器长宽比
     $aspectRatio = \max(W, H) / \min(W, H)$ 作为胶囊形与圆形的判定依据。长条胶囊
     （$aspectRatio \ge 2.2$，如长条底栏、搜索框、药丸按钮）保持水平平直高光，
     顶部在容器高度 `15%` 处归零（封顶 `10 logical px`），底部覆盖最后 `30%`（封顶 `20 logical px`），
     两端峰值平台分别封顶为 `2 / 3 logical px`（基准 `3%` / `4%`）；当容器接近正圆/正方形
     （$aspectRatio \to 1.0$，如各尺寸圆球、圆形进度指示器、按钮徽标）时，因曲面顶部水平弦长急剧收缩，
     自动切换为贴合顶部与底部外圆弧轮廓的“月牙弧光（Crescent Arc Highlight）”：高光等高线严格
     沿着圆弧向内等距推进（$d_{\text{crest}} = p.y - (-\sqrt{\max(1.0 - p.x^2, 0.0)})$），覆盖深度放宽至
     `45%`，平台保底 `12%`，衰减幂次取 `0.85`，两端随圆弧曲率优雅收窄漫射，彻底解决圆球顶部微小切片
     被 `0.36dp` 结构描边挤占问题；在长宽比 $1.0\sim 2.2$ 之间通过连续三次 Hermite 曲线平滑插值过渡，
     保证动效与 jelly 拉伸无跳变。高光仍由背景逐通道加权剩余亮度空间，并额外乘一层
     Rec.709 U 型整体亮度门控：背景亮度不超过 `0.30` 时暗端门控上限独立解耦为 `0.50`，
     将提亮增量削减约半以降低刺眼感并保留微弱通透反射，`0.30～0.50` 平滑降到 `25%`，
     `0.50～0.90` 保持低谷，`0.90～1.00` 再平滑恢复为完整曝光。暗背景因此更温和内敛，
     中间亮度不再被持续抬高，接近白色时则重新获得足以辨认的高光；白色背景的平台仍可到 `1.0`，
     平台外保留过渡，彩色背景也不会改变色相；
   - Premium、Standard 有纹理路径和交互指示器复用各自已经读取的折射背景，
     不增加纹理采样；纯黑背景不会凭空产生固定白光，彩色与纹理背景会按自身
     通道相对提亮。Standard 无纹理路径复用现有 `uBackdropLuma`，交互指示器
     的合成模式复用既有底色；Premium 物理像素兼容路径先按 DPR 换回逻辑高度。
     预乘 alpha 分支以自身 alpha 作为白点上限，旧 GLES 路径在纹理 Y 翻转前
     保存本地位置，避免透明边漏白或上下高光颠倒；
   - 浅、深两层共用外形 alpha，并根据 SDF 法线、双轴缩放与 Premium 仿射
     逆矩阵解析屏幕 SDF 梯度；方形像素的 AA 足迹使用 L1 投影
     `abs(dx) + abs(dy)`，名义线宽则单独使用 L2 梯度换算回本地 SDF 距离，
     避免 45° 圆弧少估覆盖窗口，也避免 jelly 非均匀缩放改变屏幕线宽；
     横截面继续使用线性 SDF 的“外轮廓覆盖率 - 内轮廓覆盖率”，使
      `0.36 / 0.18 logical px` 的累计描边面积在曲线角度、缩放与任意亚像素
      相位组合下保持恒定，同时兼容不支持 `fwidth` 的 Skia/SkSL；
   - `0.36 / 0.18 logical px` 现在只作为累计视觉能量；当换算结果不足一个
     物理像素时，横截面扩到 `1 physical px`，并按“名义物理宽度 / 有效宽度”
     降低条件混合权重，使高对比细线连续但不会增加累计深色重量；
   - 三条路径在轮廓窄带共用 Direct3D 8x MSAA 的零均值旋转网格：Standard、
     交互指示器与 Premium 单圆角矩形逐样本重算解析 SDF、法线、L2 宽度比例
     和左右方向权重；Premium 多形状分支逐样本读取 geometry alpha / 法线 / 高度，
     再以原线性 outer-minus-inner 覆盖率累计。完整内部直接返回满 alpha / 零描边；
   - Premium geometry texture 与解析式 SDF 都保留轮廓外侧半个物理像素的
     线性 AA 覆盖率，几何纹理四周预留一个物理像素防止提前裁切；外侧样本的
     光学距离钳制在真实边界，只改善抗锯齿，不会向玻璃外新增折射或高光；
   - 深边方向遮罩扩展为 `smoothstep(0.45, 0.90, abs(normal.x))`，使暗色从
     更早的圆角法线阶段逐渐显现，扩大浅色到深色的连续过渡；实体深边的
     `0.18 logical px` 横截面、颜色和透明度保持不变；
   - 深色色相注入深邃冷黑 `vec3(0.01, 0.015, 0.08)`，基础透明度提升至 `0.72`，
     不再叠加 `edgeAbsorption` 增益；浅色环采用提升覆盖率（`0.50`）与精准校准色
     `vec3(0.68, 0.68, 0.76)`，让描边自身建立主导覆盖力，彻底摆脱背景底色稀释，
     在任何底色上实测 B 通道均稳定反超 R/G 约 7~15 个点的高级微蓝冷调质感，
     并与左右端部的冷黑切面形成清晰硬朗的双层过渡；
   - 深色层不读取光照方向，不会跟随高光转动；镜面高光、Fresnel 与
     hairline rim 向内渐入，不再覆盖最外轮廓；
   - 共享描边函数不再把 `edgeAbsorption` 当作显示 gate；固定低透明度保证关闭
     吸收后仍有可见但不发亮的玻璃轮廓；
   - Flutter 增量 Shader 构建不会追踪本地 `#include` 依赖，三个入口文件因此
     各自保存 `edge_treatment.glsl` 规范化源码的 Adler-32 校验值。修改共享
     边缘算法时必须同步三个标记，既让入口内容变化以强制重编译，也由回归测试
     阻止旧 Shader 二进制被静默复用；
   - 解析式路径只在轮廓窄带增加八次 cache-free SDF ALU；Premium 多形状仅在
     同一窄带增加八个 cache-hot geometry 样本。上下区域高光只增加局部坐标
     `smoothstep`、背景逐通道 headroom 权重与颜色上限计算；背景折射、色散及 backdrop
     纹理读取数量不变，也不新增 uniform、`BackdropFilter`、离屏纹理或渲染 Pass。
8. Premium 多形状与复杂轮廓的 geometry texture 保持在渲染层本地坐标，并
   使用“屏幕物理像素 → 渲染层本地逻辑像素”的完整 2x3 逆仿射采样：
   - `uGeometryOffset/uGeometrySize` 保存纹理实际录制边界，不再保存旋转后丢失
     方向信息的屏幕轴对齐包围盒；
   - 纹理 alpha、SDF 法线、折射与双层终止边共用同一坐标变换，祖先平移、旋转、
     斜切或非等比缩放时不会与玻璃主体分离；
   - 法线先保留局部长度，再通过逆矩阵雅可比转回屏幕方向；左右近黑边仍按几何
     局部 `normal.x` 定向，因此会随整个底栏一起旋转，而不是锁在屏幕左右；
   - 变换追踪层在同一 scene build 内刷新逆矩阵并重新绑定 retained Shader filter，
     避免只等待下一帧 repaint 导致陀螺仪连续动画始终落后一帧；
   - CupertinoSheet 缩放冻结改用完整 X/Y 基向量长度判断，纯旋转不再因
     `cos(theta) < 1` 被误判为均匀缩放；
   - 捕获模式、透视、退化和不可逆矩阵继续使用原有兼容映射，不强行套用二维
     仿射近似，也不新增几何纹理或 backdrop Pass。
9. 新增轻量 `GlassQualityCeilingScope`，供路由转场等短生命周期动画临时限制
   子树的最高玻璃档位：
   - 只发布固定 `GlassAdaptiveScopeData`，不创建 `GlassQualityAdapter`，因此不会
     为数百毫秒的动画重复注册帧耗时回调或启动 180 帧基准测试；
   - 与外层质量取更低档，用户已选择 Minimal/Standard 时绝不被局部 Scope 升档；
   - Scope 更新或移除后立即恢复外层档位，不修改会话缓存与用户持久化偏好。
10. 完整保留官方 v1.3.0 的原生按压反馈、零分配 glow 绘制、路由退出时的
    变换追踪修复和 PlatformView 透传模式；其中 PlatformView 的 float uniform
    固定在 slot 44，避开 Poiesis 解析几何占用的 slots 32–43。普通绘制与捕获
    绘制都会显式写入该值，避免复用 FragmentShader 时继承上一帧状态。
11. `LiquidGlassSettings.refractionEnabled` 与 `topRefractionOnly` 提供独立的
    折射总开关和区域性能策略：
    - `false` 只把 Premium、Standard 与交互指示器三条 Shader 路径的背景
      法线位移、RGB 色散和 pinch 采样偏移归零；blur、tint、饱和度、光照、
      Fresnel、边缘吸收、白化、形状与交互几何保持原样；
    - 折射率、色散强度和 pinch 原始配置不会被改写，重新开启后可直接恢复；
    - Premium 使用 slot 45，普通 backdrop 与显式 capture 都逐次写入；Standard
      轻量 Shader 使用 slot 35，交互指示器使用 slot 36；
    - `copyWith`、`copyWithPinch`、`lerp`、`GlassThemeSettings`、indicator 默认
      配方合并与 grouped elevation 设置重建都传递该值，避免组件交互后回退为开启；
    - `topRefractionOnly` 默认关闭；开启后按每个玻璃组件自身的本地高度计算
      区域，顶部 `0%～16%` 保持完整折射，`16%～20%` 平滑衰减，`20%` 以下
      关闭法线位移、RGB 色散与 pinch，但继续以原坐标读取一次背景供完整材质
      合成使用；旋转、jelly 缩放、捕获模式和 GLES 纹理翻转不会改变顶部语义；
    - 三条 Shader 共用 `edge_treatment.glsl` 的区域门控函数；区域外 Premium
      同时跳过 `refract`、高度解码和相关除法。开启色散时，Standard/indicator
      的背景读取由三次降为一次，Premium 的三组手工双线性读取降为一组；
    - 区域开关分别使用 Premium slot 46、Standard slot 36 与交互指示器
      slot 37，所有复用 Shader 的宿主路径都逐次覆盖，避免跨组件状态泄漏；
    - `topRefractionOnly` 与总开关一样穿过设置复制、主题、indicator 配方和
      grouped elevation 重建；`refractionEnabled: false` 始终优先关闭全部区域。
12. 玻璃按钮（`GlassButton`、`GlassIconButton` 及按钮组外层壳体）引入专用的外部反向镂空投影：
    - 为满足轻质感悬浮需求并彻底解决半透明玻璃底色被下方阴影污染的问题，新增 `enableOuterShadow`（默认开启）与 `outerShadow` 可配置项；
    - 采用 `GlassButtonOuterShadowPainter` 配合 `PathFillType.evenOdd` 规则构建反向剪裁路径，在绘制外部模糊阴影时，将按钮几何形状内部 100% 裁切镂空，绝不渗透至半透明玻璃本体内部，保持玻璃通透澄澈；
    - 默认投影配置在 `GlassDefaults` 集中收敛（12px 模糊，(0, 2) 偏移，亮色采用带微蓝冷调补偿的冷灰阴影 `Color(0x0E0E1C44)`，暗色采用 10% 黑色 `Color(0x1A000000)`），使暖底叠加后羽化带实测呈现 224, 224, 229（高出约 5 个点）的纯净冷调；
    - 阴影与玻璃按钮主体一同置于 `LiquidStretch` 内部，按压膨胀（1.04x）或拉伸时阴影同步放大，交互自然逼真；
    - `GlassButtonStyle.transparent` 样式自动跳过外部阴影，避免复合按钮组内部子项产生多重阴影叠压。

## 回退边界

- 解析式 Premium 不依赖背景快照；显式选择 minimal、系统降低透明度或
  PlatformView 安全路径时仍遵循既有无折射回退，`blur: 0` 本身不代表禁用折射。
  需要保留材质 Shader 但关闭背景折射时使用 `refractionEnabled: false`；需要
  保留顶部折射同时降低大面积采样时使用 `topRefractionOnly: true`。
- superellipse、椭圆、上下非对称圆角以及多形状 metaball 继续使用官方几何
  texture 管线，不用近似轮廓换取性能。
- 透视、退化或不可逆变换不会强行进入解析式或二维逆仿射分支，自动回退官方
  纹理几何兼容映射。
- Skia、Web 和 PlatformView 的既有自适应策略保持不变。

## 更新上游

升级时先从 pub.dev 校验最新版与发布包 SHA-256，在 Poiesis fork 中配置官方
仓库为 `upstream`，用 merge commit 合入目标 tag，再按本文件的补丁清单逐项
语义迁移并运行测试。测试通过后快进推送 fork 的 `main`，最后在 Poiesis 主
项目中更新 submodule 指针；不要直接覆盖目录，也不要修改
`%LOCALAPPDATA%\Pub\Cache`。


## 概要任务抽屉渲染优化（2026-09-11）

任务详情抽屉通过 `preferAnalyticGeometry` 为单个上下非对称超椭圆启用最终
Shader 中的几何计算；与原几何纹理共享 Lamé 距离公式，直边区域直接求距离，
尺寸变化不再栅格化整面几何纹理。多形状与不支持的变换保留纹理路径。

`GlassSnapshot` 将现有原 DPR 概要快照直接送入 Impeller 独立玻璃层，省去
抽屉的实时 backdrop 提取，并使用硬件双线性替代每次四点手工插值。
黑色遮罩按路由原有 barrierCurve 同步，快照在 route.completed 后释放。
文本、图标、轮廓参数、顶部折射限制与材质高光保留；minimal、壁纸毛玻璃和
Skia/Web 保持各自原有分流。尚未完成真机优化前后的帧耗时与截图对照，
不能把减少纹理生成和读取次数直接等同于已测得的帧率提升。
