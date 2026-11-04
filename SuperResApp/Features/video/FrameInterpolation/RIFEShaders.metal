#include <metal_stdlib>
using namespace metal;

// ============================================================
// 1. CVPixelBuffer(BGRA) -> NCHW Float16 (归一化到 [0,1])
//    输入:  texture(BGRA)
//    输出:  device half* (NCHW)
// ============================================================
kernel void bgra_to_nchw(
    texture2d<float, access::read> src [[texture(0)]],
    device half *dst [[buffer(0)]],
    constant uint &width [[buffer(1)]],
    constant uint &height [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= width || gid.y >= height) return;

    float4 color = src.read(gid);
    uint pixelIndex = gid.y * width + gid.x;
    uint plane = width * height;

    dst[0 * plane + pixelIndex] = half(color.r);
    dst[1 * plane + pixelIndex] = half(color.g);
    dst[2 * plane + pixelIndex] = half(color.b);
}

// ============================================================
// 2. MLMultiArray(logits) -> Sigmoid 后的 mask
// ============================================================
kernel void sigmoid_mask(
    device half *mask [[buffer(0)]],
    constant uint &count [[buffer(1)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= count) return;
    float v = float(mask[gid]);
    mask[gid] = half(1.0 / (1.0 + exp(-v)));
}

// ============================================================
// 3. 按光流 Warp 一帧
//    flow: [1,4,H,W] NCHW，channelOffset 指定使用哪两个通道
//    channelOffset=0: 正向光流 (dx,dy)
//    channelOffset=2: 反向光流 (dx,dy)
//    scale: warp 时对光流的缩放（正向用 0.5，反向用 -0.5）
// ============================================================
kernel void warp_frame(
    texture2d<float, access::sample> src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    device half *flow [[buffer(0)]],
    constant uint &width [[buffer(1)]],
    constant uint &height [[buffer(2)]],
    constant float &scale [[buffer(3)]],
    constant uint &channelOffset [[buffer(4)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= width || gid.y >= height) return;

    uint pixelIndex = gid.y * width + gid.x;
    uint plane = width * height;

    float dx = float(flow[(channelOffset + 0) * plane + pixelIndex]) * scale;
    float dy = float(flow[(channelOffset + 1) * plane + pixelIndex]) * scale;

    // 采样坐标 = 像素中心(gid+0.5) + 光流位移
    // 加 0.5 是为了对齐 PyTorch grid_sample align_corners=True 的行为（角点像素中心对齐）
    // 不加会导致半像素偏移，画面模糊
    float2 sampleCoord = float2(gid) + float2(0.5) + float2(dx, dy);

    constexpr sampler s(coord::pixel, address::clamp_to_edge, filter::linear);
    float4 color = src.sample(s, sampleCoord);
    dst.write(color, gid);
}

// ============================================================
// 4. 按掩码混合两帧
//    RIFE 原始公式：warped_img0 * mask + warped_img1 * (1 - mask)
// ============================================================
kernel void blend_frames(
    texture2d<float, access::read> frame0 [[texture(0)]],
    texture2d<float, access::read> frame1 [[texture(1)]],
    texture2d<float, access::write> output [[texture(2)]],
    device half *mask [[buffer(0)]],
    constant uint &width [[buffer(1)]],
    constant uint &height [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= width || gid.y >= height) return;

    uint pixelIndex = gid.y * width + gid.x;
    float m = float(mask[pixelIndex]);

    float4 c0 = frame0.read(gid);
    float4 c1 = frame1.read(gid);

    float4 result = c0 * m + c1 * (1.0 - m);
    output.write(result, gid);
}

// ============================================================
// 5. RGBA16Float -> BGRA8Unorm（格式转换，Metal自动处理通道交换）
//    注意：写入 .bgra8Unorm 时 Metal 会自动将 RGBA 转为 BGRA 存储，
//    无需手动交换通道，否则会导致 R/B 通道二次颠倒
// ============================================================
kernel void rgba_to_bgra(
    texture2d<float, access::read> src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    float4 c = src.read(gid);
    dst.write(float4(c.r, c.g, c.b, 1.0), gid);
}

// ============================================================
// 6. 简单帧混合（快速模式用）：output = frame0 * alpha + frame1 * (1-alpha)
//    输入输出均为 BGRA8Unorm，直接在纹理上做混合
// ============================================================
kernel void simple_blend(
    texture2d<float, access::read> frame0 [[texture(0)]],
    texture2d<float, access::read> frame1 [[texture(1)]],
    texture2d<float, access::write> output [[texture(2)]],
    constant float &alpha [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    float4 c0 = frame0.read(gid);
    float4 c1 = frame1.read(gid);
    float4 result = c0 * alpha + c1 * (1.0 - alpha);
    output.write(float4(result.r, result.g, result.b, 1.0), gid);
}

// ============================================================
// 7. 光流+掩码上采样（512→原分辨率）
//    双线性插值，光流值按缩放系数放大（位移量与分辨率成正比）
//    输入: flow[4,srcH,srcW] half, mask[1,srcH,srcW] half
//    输出: flow[4,dstH,dstW] half, mask[1,dstH,dstW] half
// ============================================================
kernel void upsample_flow_mask(
    device half *srcFlow [[buffer(0)]],
    device half *srcMask [[buffer(1)]],
    device half *dstFlow [[buffer(2)]],
    device half *dstMask [[buffer(3)]],
    constant uint &srcW [[buffer(4)]],
    constant uint &srcH [[buffer(5)]],
    constant uint &dstW [[buffer(6)]],
    constant uint &dstH [[buffer(7)]],
    constant float &flowScale [[buffer(8)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= dstW || gid.y >= dstH) return;

    // 双线性插值坐标
    float fx = (float(gid.x) + 0.5) * float(srcW) / float(dstW) - 0.5;
    float fy = (float(gid.y) + 0.5) * float(srcH) / float(dstH) - 0.5;
    fx = clamp(fx, 0.0, float(srcW - 1));
    fy = clamp(fy, 0.0, float(srcH - 1));

    int x0 = int(floor(fx));
    int y0 = int(floor(fy));
    int x1 = min(x0 + 1, int(srcW - 1));
    int y1 = min(y0 + 1, int(srcH - 1));
    float wx = fx - float(x0);
    float wy = fy - float(y0);

    uint srcPlane = srcW * srcH;
    uint dstPlane = dstW * dstH;
    uint dstIdx = gid.y * dstW + gid.x;

    // 上采样 4 通道光流，乘以 flowScale
    for (uint c = 0; c < 4; c++) {
        float v00 = float(srcFlow[c * srcPlane + y0 * srcW + x0]);
        float v01 = float(srcFlow[c * srcPlane + y0 * srcW + x1]);
        float v10 = float(srcFlow[c * srcPlane + y1 * srcW + x0]);
        float v11 = float(srcFlow[c * srcPlane + y1 * srcW + x1]);
        float v = v00 * (1-wx) * (1-wy) + v01 * wx * (1-wy) + v10 * (1-wx) * wy + v11 * wx * wy;
        dstFlow[c * dstPlane + dstIdx] = half(v * flowScale);
    }

    // 上采样 1 通道 mask
    float m00 = float(srcMask[y0 * srcW + x0]);
    float m01 = float(srcMask[y0 * srcW + x1]);
    float m10 = float(srcMask[y1 * srcW + x0]);
    float m11 = float(srcMask[y1 * srcW + x1]);
    float m = m00 * (1-wx) * (1-wy) + m01 * wx * (1-wy) + m10 * (1-wx) * wy + m11 * wx * wy;
    dstMask[dstIdx] = half(m);
}
