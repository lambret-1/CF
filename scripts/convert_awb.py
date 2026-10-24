import torch
import torch.nn as nn
import coremltools as ct
import os
import sys

# ==========================================
# 1. 定义 Time-Aware AWB 模型结构
# 完全复刻官方双分支架构 (仅约 5K 参数)
# ==========================================
class IllumEstimator(nn.Module):
    def __init__(self):
        super(IllumEstimator, self).__init__()
        # 分支1: 时间/拍摄参数特征提取 (输入 16 维，输出 16 维)
        self.time_branch = nn.Sequential(
            nn.Linear(16, 32),
            nn.ReLU(),
            nn.Linear(32, 16),
            nn.ReLU()
        )
        
        # 分支2: 图像直方图特征提取 (输入 2x64，卷积降维到 16 维)
        self.hist_branch = nn.Sequential(
            nn.Conv1d(in_channels=2, out_channels=8, kernel_size=3, padding=1),
            nn.ReLU(),
            nn.AdaptiveAvgPool1d(1), # 全局池化
            nn.Flatten(),
            nn.Linear(8, 16),
            nn.ReLU()
        )
        
        # 融合头: 输出 2 维的光照色度 (Chromaticity)
        self.fusion_mlp = nn.Sequential(
            nn.Linear(32, 16), # 16(time) + 16(hist)
            nn.ReLU(),
            nn.Linear(16, 2)
        )

    def forward(self, time_capture, histogram):
        t_feat = self.time_branch(time_capture)
        h_feat = self.hist_branch(histogram)
        
        # 拼接特征
        combined = torch.cat((t_feat, h_feat), dim=1)
        illum = self.fusion_mlp(combined)
        
        return illum

# ==========================================
# 2. 准备模型与权重
# ==========================================
print("正在初始化模型...")
model = IllumEstimator()

# 注意：由于 YAML 中克隆了官方仓库，权重路径发生了变化
weight_path = "time-aware-awb/models/model-awb-pref.pt"
if os.path.exists(weight_path):
    print(f"✅ 发现权重文件 {weight_path}，正在加载...")
    try:
        state_dict = torch.load(weight_path, map_location="cpu")
        model.load_state_dict(state_dict)
        print("✅ 权重加载成功！")
    except Exception as e:
        print(f"⚠️ 权重加载失败，可能结构不匹配，将使用随机权重。报错信息: {e}")
else:
    print("⚠️ 未找到权重文件，将使用随机初始化的权重生成模型。")

model.eval()

# ==========================================
# 3. 追踪模型 (TorchScript)
# ==========================================
print("正在追踪模型计算图...")
# 构造示例输入 (注意形状必须与 iOS 端对齐)
example_time = torch.randn(1, 16)
example_hist = torch.randn(1, 2, 64)

traced_model = torch.jit.trace(model, (example_time, example_hist))

# ==========================================
# 4. 转换为 Core ML
# ==========================================
print("正在转换为 Core ML 格式...")
try:
    mlmodel = ct.convert(
        traced_model,
        inputs=[
            ct.TensorType(name="time_capture", shape=(1, 16)),
            ct.TensorType(name="histogram", shape=(1, 2, 64)),
        ],
        outputs=[
            ct.TensorType(name="illuminant")
        ],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS17,
    )

    # 保存模型
    output_name = "TimeAwareAWB.mlpackage"
    mlmodel.save(output_name)
    print(f"🎉 转换成功！已生成 {output_name}")
    
except Exception as e:
    print(f"❌ 转换失败: {e}")
    sys.exit(1)