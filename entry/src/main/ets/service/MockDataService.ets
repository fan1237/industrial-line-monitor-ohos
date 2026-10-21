import { SensorData } from '../model/SensorData'
import { IDataService } from './IDataService'

// 模拟数据源：每秒用随机数模拟温湿度/光电传感器。
// 真实接入时，新建 MqttDataService implements IDataService 替换它即可。
export class MockDataService implements IDataService {
  private timer: number = -1
  private dataCb: (d: SensorData) => void = () => {}
  private commandCb: (cmd: string, status: string) => void = () => {}

  onData(cb: (d: SensorData) => void): void {
    this.dataCb = cb
  }

  onCommand(cb: (cmd: string, status: string) => void): void {
    this.commandCb = cb
  }

  sendCommand(cmd: string, newStatus: string): void {
    // 真实实现：SM4 加密指令 → 发 MQTT → 服务器校验后下 PLC → 状态经 onCommand 回推
    // Mock 实现：直接回调，模拟"下发成功"
    this.commandCb(cmd, newStatus)
  }

  start(): void {
    if (this.timer !== -1) return
    this.timer = setInterval(() => {
      this.dataCb({
        temp: Number((20 + Math.random() * 15).toFixed(1)),
        humi: Number((40 + Math.random() * 40).toFixed(1)),
        sensor: Math.random() > 0.5
      })
    }, 1000)
  }

  stop(): void {
    if (this.timer !== -1) {
      clearInterval(this.timer)
      this.timer = -1
    }
  }
}
