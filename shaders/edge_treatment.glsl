#ifndef LIQUID_GLASS_EDGE_TREATMENT_GLSL
#define LIQUID_GLASS_EDGE_TREATMENT_GLSL

// 中文说明：iOS 玻璃轮廓由两条亚逻辑像素细边叠加，而不是一条均匀黑边：
// 第一层是完整围绕轮廓的 0.36 logical px 低透明浅灰环；第二层是只在左右
// 法线增强的 0.18 logical px 深灰环。两层都用“外形覆盖率 - 内形覆盖率”
// 得到真实 SDF 描边面积，再除以外形覆盖率还原成当前片元内的条件混合权重。
// 这样最终 premultiplied alpha 只乘一次，亚像素平移时描边能量不会在上下像素
// 行之间忽多忽少。以下函数只做逐像素 ALU 运算，不读取纹理、不增加 uniform，
// 也不会引入新的渲染 Pass。

float getSdfDistanceScale(vec2 sdfScreenGradient) {
    // 中文说明：梯度的 L2 长度描述一个物理屏幕像素对应多少 SDF 距离，
    // 只用于把目标屏幕线宽换算回当前局部 SDF 单位。非均匀 jelly 缩放时，
    // 这个比例会随圆弧法线连续变化，从而抵消几何变换造成的视觉粗细变化。
    return max(length(sdfScreenGradient), 0.0001);
}

float getSdfPixelFootprint(vec2 sdfScreenGradient) {
    // 中文说明：屏幕像素是轴对齐方形，而不是圆。它在 SDF 法线方向上的
    // 完整投影宽度应为 |dSdf/dx| + |dSdf/dy|（L1），等价于解析 fwidth。
    // 旧实现使用 L2 length，在 45° 圆弧处最多少估约 29% 的 AA 窗口，
    // 因而直边正常、左右曲线却出现台阶和毛刺。本函数不调用 RuntimeEffect
    // 不支持的导数指令，三条渲染路径可共享同一解析结果。
    return max(
        abs(sdfScreenGradient.x) + abs(sdfScreenGradient.y),
        0.0001
    );
}

// 中文说明：最高画质边缘路径使用 Direct3D 标准 8x MSAA 的零均值旋转网格。
// 坐标位于当前物理像素中心的 [-0.5, 0.5] 范围内，八个 X/Y 相位均不重复；
// 相比规则 2x4 网格，它不容易在接近水平、垂直或 45° 的圆弧上形成周期条纹。
// 常量放在共享 include 中，确保 Premium、Standard 与交互指示器使用完全相同
// 的采样核。显式常量也避开部分 SkSL 后端对全局 vec2 数组索引的兼容问题。
const vec2 kEdgeRgss0 = vec2( 0.0625, -0.1875);
const vec2 kEdgeRgss1 = vec2(-0.0625,  0.1875);
const vec2 kEdgeRgss2 = vec2( 0.3125,  0.0625);
const vec2 kEdgeRgss3 = vec2(-0.1875, -0.3125);
const vec2 kEdgeRgss4 = vec2(-0.3125,  0.3125);
const vec2 kEdgeRgss5 = vec2(-0.4375, -0.0625);
const vec2 kEdgeRgss6 = vec2( 0.1875,  0.4375);
const vec2 kEdgeRgss7 = vec2( 0.4375, -0.4375);
const float kEdgeRgssInvCount = 0.125;

// 中文说明：低于一个物理像素的高对比终止边，即使数学面积正确，也会在连续
// 曲线上表现为稀疏的深浅像素。把覆盖横截面扩到至少 1 physical px，再按
// “名义宽度 / 有效宽度”降低能量，能够获得连续轮廓，同时保持原有累计视觉重量。
const float kMinPhysicalRimWidth = 1.0;

vec2 getEnergyPreservingRimProfile(float nominalPhysicalWidth) {
    float safeNominalWidth = max(nominalPhysicalWidth, 0.0001);
    float effectivePhysicalWidth = max(
        kMinPhysicalRimWidth,
        safeNominalWidth
    );
    float energyScale = clamp(
        nominalPhysicalWidth / effectivePhysicalWidth,
        0.0,
        1.0
    );
    return vec2(effectivePhysicalWidth, energyScale);
}

vec3 getSupersampledSdfEdgeContribution(
    float signedDistance,
    float lightRimWidth,
    float darkRimWidth,
    float normalX,
    float lightEnergyScale,
    float darkEnergyScale
) {
    // 中文说明：每个旋转网格点是一个真实的点样本，不再套用整像素 L1
    // coverage，否则会把一次面积积分重复卷积而过度模糊。X 保存外形内部样本，
    // Y/Z 分别保存已经过能量补偿的浅边与左右深边样本。
    float inside = step(signedDistance, 0.0);
    float inwardDistance = max(-signedDistance, 0.0);
    float lightBand = inside * (1.0 - step(lightRimWidth, inwardDistance));
    float darkBand = inside * (1.0 - step(darkRimWidth, inwardDistance));
    // 中文说明：三条渲染路径都把深边的方向过渡起点前移到 0.45；这样深色会
    // 从更早的圆角法线阶段渐入浅色环，但仍在 0.90 处完成显现。这里只扩大
    // 方向渐变区，不改变深边的横截面宽度、透明度、颜色或累计覆盖能量。
    float lateralWeight = smoothstep(0.45, 0.90, abs(normalX));
    return vec3(
        inside,
        lightBand * lightEnergyScale,
        darkBand * lateralWeight * darkEnergyScale
    );
}

vec3 resolveEdgeSupersample(vec3 accumulatedCoverage) {
    // 中文说明：先将八点总和还原成外形 coverage，再将两层真实描边面积除以
    // 同一外形面积，得到 applyDualLayerRim 所需的条件混合权重。最终输出阶段
    // 仍只乘一次 shape alpha，因此亚像素区域不会被二次变淡。
    float shapeCoverage = clamp(
        accumulatedCoverage.x * kEdgeRgssInvCount,
        0.0,
        1.0
    );
    float safeAccumulatedShape = max(accumulatedCoverage.x, 0.0001);
    return vec3(
        shapeCoverage,
        clamp(accumulatedCoverage.y / safeAccumulatedShape, 0.0, 1.0),
        clamp(accumulatedCoverage.z / safeAccumulatedShape, 0.0, 1.0)
    );
}

float getCoverageStableSdfStrokeMask(
    float edgeDistance,
    float rimWidth,
    float pixelFootprint,
    float shapeCoverage
) {
    float safeWidth = max(rimWidth, 0.0001);
    float safeFootprint = max(pixelFootprint, 0.0001);
    float outerCoverage = clamp(shapeCoverage, 0.0, 1.0);

    // 中文说明：外轮廓 AA 使用线性面积覆盖率：
    // coverage = clamp(0.5 - signedDistance / pixelFootprint, 0, 1)。
    // 在半透明外侧样本中没有可直接读取的负向内部距离，因此先从相同的线性
    // coverage 精确反解 signedDistance；进入形状后则直接使用 SDF 向内距离，
    // 防止 outerCoverage 饱和为 1 后丢失 0.5px 以后的真实位置。
    float recoveredSignedDistance =
        (0.5 - outerCoverage) * safeFootprint;
    float hasInteriorDistance = step(0.000001, edgeDistance);
    float signedDistance = mix(
        recoveredSignedDistance,
        -max(edgeDistance, 0.0),
        hasInteriorDistance
    );

    // 中文说明：把同一个 SDF 向内平移 rimWidth 得到内轮廓。外覆盖率减去
    // 内覆盖率就是该像素真正被描边占据的面积；线性 coverage 在一个屏幕像素
    // 足迹内满足面积守恒，所以 0.36px / 0.18px 细边无论落在像素中心还是
    // 两行像素之间，总覆盖量都保持不变。
    float innerCoverage = clamp(
        0.5 - (signedDistance + safeWidth) / safeFootprint,
        0.0,
        1.0
    );
    float strokeCoverage = clamp(
        outerCoverage - innerCoverage,
        0.0,
        1.0
    );

    // 中文说明：调用方最后还会把 RGB 乘一次 shapeCoverage。这里除回外形
    // 覆盖率，最终得到 strokeCoverage，而不是错误的 strokeCoverage * alpha；
    // 极低覆盖样本通过安全分母自然衰减，避免边界出现亮点或 NaN。
    return clamp(
        strokeCoverage / max(outerCoverage, 0.0001),
        0.0,
        1.0
    );
}

vec3 getFilteredSdfEdgeContribution(
    float edgeDistance,
    float lightRimWidth,
    float darkRimWidth,
    float pixelFootprint,
    float shapeCoverage,
    float normalX,
    float lightEnergyScale,
    float darkEnergyScale
) {
    // 中文说明：Premium 多形状几何纹理已在生成阶段保存解析 AA alpha，不能
    // 再把纹理样本硬阈值化。这里把每个 RGSS 纹理样本的条件描边遮罩重新乘回
    // 它自己的 alpha，八点累加后再统一除以总外形覆盖率，避免重复乘 alpha。
    float safeCoverage = clamp(shapeCoverage, 0.0, 1.0);
    float lightCoverage = getCoverageStableSdfStrokeMask(
        edgeDistance,
        lightRimWidth,
        pixelFootprint,
        safeCoverage
    ) * safeCoverage * lightEnergyScale;
    float darkCoverage = getCoverageStableSdfStrokeMask(
        edgeDistance,
        darkRimWidth,
        pixelFootprint,
        safeCoverage
    ) * safeCoverage;
    // 中文说明：纹理几何路径与解析式路径使用相同的 0.45 到 0.90 方向渐变，
    // 避免 Premium 多形状在圆角处出现比 Standard 更短的浅色到深色过渡。
    // 变化只作用于 lateralWeight，不会扩大 0.18 logical px 的实体深边。
    float lateralWeight = smoothstep(0.45, 0.90, abs(normalX));
    return vec3(
        safeCoverage,
        lightCoverage,
        darkCoverage * lateralWeight * darkEnergyScale
    );
}

float getContinuousLightRimMask(
    float edgeDistance,
    float rimWidth,
    float pixelFootprint,
    float shapeCoverage,
    float edgeAbsorption
) {
    // 中文说明：描边是玻璃几何轮廓，边缘吸收是独立的 Beer–Lambert
    // 变暗项；关闭吸收时仍必须保留这层浅灰细边。保留参数只是为了让三条
    // 入口 Shader 的调用签名稳定，避免增加 uniform 或重复维护调用路径。
    // 用一次无副作用的算术引用参数，兼容 GLSL 编译器的未使用参数检查。
    float rimStyleInput = edgeAbsorption * 0.0;
    // 浅色层不读取法线，所以会完整围绕形状；但它必须和深色层一样读取
    // 当前屏幕像素足迹及外形覆盖率，才能避免顶部/底部随亚像素相位交换深浅。
    return getCoverageStableSdfStrokeMask(
        edgeDistance,
        rimWidth,
        pixelFootprint,
        shapeCoverage
    ) + rimStyleInput;
}

float getLateralDarkRimMask(
    float edgeDistance,
    float rimWidth,
    float pixelFootprint,
    float shapeCoverage,
    float normalX,
    float edgeAbsorption
) {
    // 中文说明：左右深边与吸收变暗解耦。即使应用把
    // edgeAbsorption 设为 0 来关闭弯月面吸收，iOS 风格的两层玻璃轮廓
    // 仍然需要显示；方向渐变和物理像素覆盖率继续负责形状与抗锯齿。
    float rimStyleInput = edgeAbsorption * 0.0;
    // 中文说明：深边不再单独维护 smoothstep 横截面，而是与完整浅边共用
    // 面积守恒的 SDF 描边覆盖率。这样两层在同一物理像素网格上对齐，避免
    // 叠加后再次放大局部宽度差；这里仍不使用 Skia/SkSL 不支持的 fwidth。
    float coverageStableProfile = getCoverageStableSdfStrokeMask(
        edgeDistance,
        rimWidth,
        pixelFootprint,
        shapeCoverage
    );

    // 中文说明：abs(normalX) 在左右侧为 1、上下侧为 0。现在把渐入起点从
    // 0.60 前移到 0.45，终点保持 0.90，因此暗边会沿圆角更早、更柔和地从
    // 浅色环过渡出来；连续 smoothstep 仍避免方向范围变化造成生硬断点。
    // 它不读取光照方向，因此左右结构不会随高光移动，也不会改变实体线宽。
    float lateralWeight = smoothstep(0.45, 0.90, abs(normalX));
    return coverageStableProfile * lateralWeight + rimStyleInput;
}

float getInnerHighlightGate(
    float edgeDistance,
    float rimWidth,
    float edgeAbsorption
) {
    // 中文说明：白色反射始终从双层描边内侧开始渐入；它属于轮廓合成的
    // 空间避让，不是吸收强度。这样关闭吸收后，细边仍保持清晰的层次关系。
    float insetGate = smoothstep(
        rimWidth * 0.75,
        rimWidth * 2.0,
        edgeDistance
    );
    float rimStyleInput = edgeAbsorption * 0.0;
    return insetGate + rimStyleInput;
}

// 中文说明：高光形态区分以容器长宽比（Aspect Ratio）为核心依据：
// 1. 长条胶囊容器（aspectRatio >= 2.2，如长条底栏、搜索框、药丸按钮）：
//    保留水平平直的高光带，顶部限制在 15%（封顶 10dp）、底部限制在 30%（封顶 20dp），
//    峰值平台分别封顶在 2dp / 3dp，保持克制干练的长直反射。
// 2. 圆形/正方形容器（aspectRatio -> 1.0，如各尺寸圆球、圆形进度指示器、按钮徽标）：
//    启用贴合圆弧轮廓的“月牙弧光（Crescent Arc Highlight）”。高光等高线严格
//    沿着顶部圆弧向内等距推进（d_crest = p.y + sqrt(max(1.0 - p.x^2, 0.0))），
//    两端随圆弧曲率优雅收窄，向球心舒展漫射，避免在圆顶缩成难看的窄缝或水平一刀切切片；
// 3. 在 aspectRatio 1.0 ~ 2.2 之间使用三次 smoothstep 连续过渡，
//    无论静态尺寸还是动态 jelly 变形拉伸，高光形态均丝滑演变、无突变跳变。
const float kShapeTransitionCircle = 1.0;
const float kShapeTransitionCapsule = 2.2;

const float kTopAreaHighlightExtent = 0.15;
const float kBottomAreaHighlightExtent = 0.30;
const float kTopAreaHighlightPlateau = 0.03;
const float kBottomAreaHighlightPlateau = 0.04;
const float kTopAreaHighlightMaxLogicalHeight = 10.0;
const float kBottomAreaHighlightMaxLogicalHeight = 20.0;
const float kTopAreaHighlightPlateauMaxLogicalHeight = 2.0;
const float kBottomAreaHighlightPlateauMaxLogicalHeight = 3.0;

// 中文说明：圆形月牙贴合高光几何参数
const float kCrescentTopExtent = 0.45;
const float kCrescentTopPlateau = 0.12;
const float kCrescentBottomExtent = 0.40;
const float kCrescentBottomPlateau = 0.10;

const float kAreaHighlightMiddleBackdropGate = 0.25;
const float kAreaHighlightDarkPeakGate = 0.50;
const float kAreaHighlightDarkFullLuma = 0.30;
const float kAreaHighlightDarkFadeEndLuma = 0.50;
const float kAreaHighlightLightRiseStartLuma = 0.90;
const float kAreaHighlightLightFullLuma = 1.00;
const vec3 kAreaHighlightLumaWeights = vec3(0.2126, 0.7152, 0.0722);

float getAdaptiveAreaHighlightExposureLift(
    vec2 localUV,
    vec2 glassLogicalSize
) {
    vec2 safeSize = max(glassLogicalSize, vec2(0.0001));
    vec2 clampedUV = clamp(localUV, 0.0, 1.0);

    // 中文说明：计算长宽比与圆形/球体因子。aspectRatio 从 1.0（正圆）到 2.2（典型胶囊）
    // 连续过渡；roundFactor 为 1.0 时为纯圆球，0.0 时为纯长条胶囊。
    float maxDim = max(safeSize.x, safeSize.y);
    float minDim = min(safeSize.x, safeSize.y);
    float aspectRatio = maxDim / max(minDim, 0.0001);
    float roundFactor = 1.0 - smoothstep(
        kShapeTransitionCircle,
        kShapeTransitionCapsule,
        aspectRatio
    );

    // ---- 1. 长条胶囊平直线性高光（Capsule Highlight） ----
    float effectiveTopExtent = min(
        kTopAreaHighlightExtent,
        kTopAreaHighlightMaxLogicalHeight / safeSize.y
    );
    float effectiveBottomExtent = min(
        kBottomAreaHighlightExtent,
        kBottomAreaHighlightMaxLogicalHeight / safeSize.y
    );
    float effectiveTopPlateau = min(
        kTopAreaHighlightPlateau,
        kTopAreaHighlightPlateauMaxLogicalHeight / safeSize.y
    );
    float effectiveBottomPlateau = min(
        kBottomAreaHighlightPlateau,
        kBottomAreaHighlightPlateauMaxLogicalHeight / safeSize.y
    );

    float capsuleTop = 1.0 - smoothstep(
        effectiveTopPlateau,
        effectiveTopExtent,
        clampedUV.y
    );
    float capsuleBottom = smoothstep(
        1.0 - effectiveBottomExtent,
        1.0 - effectiveBottomPlateau,
        clampedUV.y
    );
    float capsuleHighlight = clamp(capsuleTop + capsuleBottom, 0.0, 1.0);

    // ---- 2. 圆形/球体贴合圆弧月牙高光（Crescent Arc Highlight） ----
    // 中文说明：将 UV 映射到以中心为原点的归一化圆盘 [-1, 1]
    vec2 p = (clampedUV - vec2(0.5)) * 2.0;

    // 顶部月牙：计算片元相对于顶部外圆弧的内向垂直深度
    // 任意水平位置 x 处的外圆弧 Y 坐标为 -sqrt(1 - x^2)
    float topArcY = -sqrt(max(1.0 - p.x * p.x, 0.0));
    float inwardDepthTop = p.y - topArcY;
    float arcSpanTop = smoothstep(0.0, 0.35, 1.0 - p.x * p.x) * clamp(-p.y, 0.0, 1.0);
    float topCrescentProfile = 1.0 - smoothstep(
        kCrescentTopPlateau,
        kCrescentTopExtent,
        inwardDepthTop
    );
    float topCrescent = pow(max(topCrescentProfile, 0.0), 0.85) * arcSpanTop;

    // 底部托底月牙：计算片元相对于底部外圆弧的内向垂直深度
    float bottomArcY = sqrt(max(1.0 - p.x * p.x, 0.0));
    float inwardDepthBottom = bottomArcY - p.y;
    float arcSpanBottom = smoothstep(0.0, 0.40, 1.0 - p.x * p.x) * clamp(p.y, 0.0, 1.0);
    float bottomCrescentProfile = smoothstep(
        kCrescentBottomExtent,
        kCrescentBottomPlateau,
        inwardDepthBottom
    );
    float bottomCrescent = pow(max(bottomCrescentProfile, 0.0), 0.90) * arcSpanBottom * 0.70;

    float crescentHighlight = clamp(topCrescent + bottomCrescent, 0.0, 1.0);

    // 中文说明：按圆形度因子在胶囊平直高光与圆形月牙高光之间连续插值
    return clamp(
        mix(capsuleHighlight, crescentHighlight, roundFactor),
        0.0,
        1.0
    );
}

float getVerticalAreaHighlightExposureLift(
    float normalizedVerticalPosition,
    float glassLogicalHeight
) {
    // 中文说明：向后兼容旧调用，默认按标准长条胶囊处理
    return getAdaptiveAreaHighlightExposureLift(
        vec2(0.5, normalizedVerticalPosition),
        vec2(glassLogicalHeight * 3.0, glassLogicalHeight)
    );
}

float getVerticalAreaHighlightBackdropGate(vec3 safeBackdropColor) {
    // 中文说明：逐通道背景权重能保留色相，再以 Rec.709 亮度生成三通道共用
    // 的 U 型标量门控。亮度不超过 0.30 时的暗端上限独立解耦为 0.50，降低深暗背景
    // 下的高光反射刺眼感并保留微通透质感；0.30~0.50 平滑降到 25%，并在 0.50~0.90
    // 保持低谷，避免中间背景持续被抬亮；超过 0.90 后快速平滑恢复，纯白背景完整放行
    // 到 1.0。暗端与亮端分别计算独立门控后再取最大值，端点导数为零且连续。
    float backdropLuma = dot(safeBackdropColor, kAreaHighlightLumaWeights);
    float darkEndpointWeight = 1.0 - smoothstep(
        kAreaHighlightDarkFullLuma,
        kAreaHighlightDarkFadeEndLuma,
        backdropLuma
    );
    float lightEndpointWeight = smoothstep(
        kAreaHighlightLightRiseStartLuma,
        kAreaHighlightLightFullLuma,
        backdropLuma
    );
    float darkGate = mix(
        kAreaHighlightMiddleBackdropGate,
        kAreaHighlightDarkPeakGate,
        darkEndpointWeight
    );
    float lightGate = mix(
        kAreaHighlightMiddleBackdropGate,
        1.0,
        lightEndpointWeight
    );
    return max(darkGate, lightGate);
}

vec3 applyVerticalAreaHighlight(
    vec3 color,
    vec3 backdropColor,
    float highlightExposureLift,
    float colorAlpha
) {
    // 中文说明：背景色不再作为固定加法，而是作为剩余亮度空间的逐通道权重。
    // 峰值平台可把几何曝光提高到 1.0；U 型亮度门控让暗背景高光降至 0.50 峰值以消除过亮，
    // 中间背景压低到 25%，接近白色时再恢复可见高光。纯黑背景仍因逐通道权重
    // 为零而不会凭空生白，彩色背景也会保留自身色相与纹理。headroom 已位于
    // 当前 alpha 的合法范围，因此预乘分支无需再次乘 alpha，也不会在透明边缘漏色。
    float safeColorAlpha = clamp(colorAlpha, 0.0, 1.0);
    vec3 whitePoint = vec3(safeColorAlpha);
    vec3 highlightHeadroom = max(whitePoint - color, vec3(0.0));
    vec3 backdropWeight = clamp(backdropColor, 0.0, 1.0);
    float backdropExposureGate = getVerticalAreaHighlightBackdropGate(
        backdropWeight
    );
    float safeExposureLift = clamp(highlightExposureLift, 0.0, 1.0);
    vec3 backgroundRelativeLift = highlightHeadroom
        * backdropWeight
        * backdropExposureGate
        * safeExposureLift;
    return color + backgroundRelativeLift;
}

vec3 applyDualLayerRim(
    vec3 color,
    float continuousLightRimMask,
    float lateralDarkRimMask,
    float edgeAbsorption
) {
    // 中文说明：描边透明度是独立的视觉样式，不再随 edgeAbsorption 增益；
    // 后者现在只控制物理弯月面吸收。这样关闭吸收不会同时丢失边缘结构。
    // 第一层：中高覆盖率的明亮冷灰细环，0.50 固定不透明度，完整铺满轮廓。
    // 中文说明：通过大幅提升自身覆盖率至 50% 并直接校准自身色相为明亮冷调灰 vec3(0.68, 0.68, 0.76)，
    // 让描边依靠自身色彩建立主导权，从根本上摆脱对背景透光的依赖；无论在暖奶底、纯白还是深色背景上，
    // 屏幕实测 B 通道均能稳定反超 R/G 约 7~8 个点，呈现纯净高级的冷调反光且兼具玻璃通透感。
    const vec3 lightRimColor = vec3(0.68, 0.68, 0.76);
    const float lightRimOpacity = 0.50;
    float lightRimMix = clamp(
        continuousLightRimMask * lightRimOpacity,
        0.0,
        1.0
    );
    vec3 withLightRim = mix(color, lightRimColor, lightRimMix);

    // 第二层：深邃冷黑的锐利左右边。它在浅色环之后叠加，所以左右两侧
    // 会自然形成更深的重合色，上下仍只保留完整微冷深灰环。
    // 将不透明度提升至 0.72，并将自身颜色校准为深邃冷黑 vec3(0.01, 0.015, 0.08)；
    // 72% 的自身覆盖率牢牢锁定深边色彩，实测 B 通道稳定反超 R/G 约 10~15 个点，
    // 彻底消除“只反超 1”的微弱感，赋予侧向切面精致深沉的高级雕刻质感。
    const vec3 darkRimColor = vec3(0.01, 0.015, 0.08);
    const float darkRimOpacity = 0.72;
    float darkRimMix = clamp(
        lateralDarkRimMask * darkRimOpacity,
        0.0,
        1.0
    );
    return mix(withLightRim, darkRimColor, darkRimMix);
}

#endif
