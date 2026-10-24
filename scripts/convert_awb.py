import torch
import coremltools as ct
import sys
sys.path.insert(0, "time-aware-awb") # 指向官方模型代码目录
from model import IllumEstimator # 根据官方代码调整导入的类名

# 1. 初始化并加载 PyTorch 权重
model = IllumEstimator()
model.load_state_dict(torch.load("weights/awb_final.pth", map_location="cpu"))
model.eval()

# 2. 构造示例输入并进行 TorchScript 追踪
# 注意：请根据官方代码确认输入的具体形状和维度
example_time = torch.randn(1, 16)      # 时间-拍摄特征
example_hist = torch.randn(1, 2, 64)   # 色度直方图特征
traced_model = torch.jit.trace(model, (example_time, example_hist))

# 3. 转换为 Core ML (.mlpackage)
mlmodel = ct.convert(
    traced_model,
    inputs=[
        ct.TensorType(name="time_capture", shape=(1, 16)),
        ct.TensorType(name="histogram",   shape=(1, 2, 64)),
    ],
    convert_to="mlprogram",            # 使用更现代的 mlprogram 格式
    compute_precision=ct.precision.FLOAT16, # ANE 推荐精度
    minimum_deployment_target=ct.target.iOS17,
)

mlmodel.save("TimeAwareAWB.mlpackage")
print("✅ 转换成功：TimeAwareAWB.mlpackage")