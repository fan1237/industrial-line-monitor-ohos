// 产线状态相关模型（模块一）

// 单个核心工序的执行情况
export interface ProcessStep {
  name: string      // 工序名：上料 / 装配 / 检测 / 打包 / 入库
  progress: number  // 0-100
  status: string    // 待执行 / 执行中 / 已完成
}

// 物理产线的一盏指示灯
export interface LineIndicator {
  name: string      // 运行 / 停止 / 故障 / 复位
  on: boolean       // 是否点亮
}

// APP 从智能计算场景单元订阅到的产线状态
export interface LineState {
  processes: ProcessStep[]
  indicators: LineIndicator[]
}
