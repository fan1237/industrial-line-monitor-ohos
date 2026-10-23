import { SensorData } from '../model/SensorData'
import { LineState } from '../model/LineState'

// 数据源统一接口：把"数据从哪来"和"UI 怎么用"解耦。
// 现在是 MockDataService 模拟数据；拿到真实接口协议后，
// 新增一个 MqttDataService implements IDataService 替换即可，UI 不用改。
export interface IDataService {
  // 收到一条传感器数据时回调
  onData(cb: (d: SensorData) => void): void
  // 收到服务器回推的产线状态时回调（控制指令下发成功后的状态变化）
  onCommand(cb: (cmd: string, status: string) => void): void
  // 收到产线工序进度与物理指示灯状态时回调
  onLineState(cb: (s: LineState) => void): void
  // 下发控制指令（启动/停止/复位）
  sendCommand(cmd: string, newStatus: string): void
  // 启动 / 停止数据源
  start(): void
  stop(): void
}
