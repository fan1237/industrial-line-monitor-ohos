import { SensorData } from '../model/SensorData'
import { LineState, ProcessStep, LineIndicator } from '../model/LineState'
import { IDataService } from './IDataService'

// 核心工序（模块一要求：上料 / 装配 / 检测 / 打包 / 入库）
const STEP_NAMES: string[] = ['上料', '装配', '检测', '打包', '入库']

function createProcesses(): ProcessStep[] {
  const list: ProcessStep[] = []
  for (const name of STEP_NAMES) {
    list.push({ name: name, progress: 0, status: '待执行' })
  }
  return list
}

// 模拟数据源：每秒用随机数模拟温湿度/光电传感器，并推进工序进度与指示灯状态。
// 真实接入时，新建 MqttDataService implements IDataService 替换它即可，UI 不用改。
export class MockDataService implements IDataService {
  private timer: number = -1
  private resetTimer: number = -1
  private dataCb: (d: SensorData) => void = () => {}
  private commandCb: (cmd: string, status: string) => void = () => {}
  private stateCb: (s: LineState) => void = () => {}
  private running: boolean = true
  private status: string = '运行中'
  private processes: ProcessStep[] = createProcesses()

  onData(cb: (d: SensorData) => void): void {
    this.dataCb = cb
  }

  onCommand(cb: (cmd: string, status: string) => void): void {
    this.commandCb = cb
  }

  onLineState(cb: (s: LineState) => void): void {
    this.stateCb = cb
  }

  sendCommand(cmd: string, newStatus: string): void {
    // 真实实现：SM4 加密指令 → 发 MQTT → 服务器校验后下 PLC → 状态经 onCommand 回推
    if (cmd === '启动') {
      this.running = true
      this.status = newStatus
      this.commandCb(cmd, newStatus)
    } else if (cmd === '停止') {
      this.running = false
      this.status = newStatus
      this.commandCb(cmd, newStatus)
    } else if (cmd === '复位') {
      this.running = false
      this.status = '复位中'
      this.resetProcesses()
      this.commandCb(cmd, '复位中')
      // 复位动作耗时约 2 秒，完成后回到停止状态
      this.resetTimer = setTimeout(() => {
        this.status = '停止'
        this.commandCb('复位完成', '停止')
        this.resetTimer = -1
      }, 2000)
    } else {
      this.status = newStatus
      this.commandCb(cmd, newStatus)
    }
  }

  start(): void {
    if (this.timer !== -1) return
    this.timer = setInterval(() => {
      this.dataCb({
        temp: Number((20 + Math.random() * 15).toFixed(1)),
        humi: Number((40 + Math.random() * 40).toFixed(1)),
        sensor: Math.random() > 0.5
      })
      if (this.running) {
        this.advanceProcess()
      }
      this.stateCb({
        processes: this.cloneProcesses(),
        indicators: this.buildIndicators()
      })
    }, 1000)
  }

  stop(): void {
    if (this.timer !== -1) {
      clearInterval(this.timer)
      this.timer = -1
    }
    if (this.resetTimer !== -1) {
      clearTimeout(this.resetTimer)
      this.resetTimer = -1
    }
  }

  // 推进当前工序进度；全部完成后自动进入下一轮生产
  private advanceProcess(): void {
    const list = this.processes
    for (let i = 0; i < list.length; i++) {
      const step: ProcessStep = list[i]
      if (step.status === '已完成') continue
      step.status = '执行中'
      step.progress += 4
      if (step.progress >= 100) {
        step.progress = 100
        step.status = '已完成'
        const next: ProcessStep | undefined = list[i + 1]
        if (next !== undefined) {
          next.status = '执行中'
        }
      }
      return
    }
    this.resetProcesses()
  }

  private resetProcesses(): void {
    for (const step of this.processes) {
      step.progress = 0
      step.status = '待执行'
    }
  }

  // 对外传副本，避免 UI 直接持有同一批对象引用
  private cloneProcesses(): ProcessStep[] {
    const out: ProcessStep[] = []
    for (const step of this.processes) {
      out.push({ name: step.name, progress: step.progress, status: step.status })
    }
    return out
  }

  // 物理产线指示灯：运行 / 停止 / 故障 / 复位
  private buildIndicators(): LineIndicator[] {
    const out: LineIndicator[] = []
    out.push({ name: '运行', on: this.running && this.status !== '异常' })
    out.push({ name: '停止', on: !this.running && this.status === '停止' })
    out.push({ name: '故障', on: this.status === '异常' })
    out.push({ name: '复位', on: this.status === '复位中' })
    return out
  }
}
