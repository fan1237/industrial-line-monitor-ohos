import fs from '@ohos.file.fs'
import { SensorData } from '../model/SensorData'
import { IDataService } from '../service/IDataService'
import { MockDataService } from '../service/MockDataService'
import { HistoryPoint } from '../model/HistoryPoint'
import { HistoryStore } from '../service/HistoryStore'
import { CryptoService } from '../service/CryptoService'
import { CryptoCheckResult } from '../service/CryptoService'
import { ProtocolService } from '../service/ProtocolService'
import { LineState, ProcessStep, LineIndicator } from '../model/LineState'

// 报警数据
interface AlarmItem {
  id: string
  type: string
  time: number
  location: string
  level: string
  status: string
}

// 订单数据
interface OrderItem {
  id: string
  product: string
  qty: number//数量
  priority: string   // 优先级，高 / 中 / 低
  status: string     // 待生产 , 生产中 /已完成
  createTime: number//订单创建时间
  finishTime: number//订单完成时间
  progress: number   // 0-100%，进度
}

@Entry
@Component
struct Index {
  @State temp: number = 25.6
  @State humi: number = 60
  @State lineStatus: string = '运行中'
  @State logs: string[] = []
  @State sensor: boolean = true
  @State tempHistory: number[] = []
  @State humiHistory: number[] = []
  // 模块一：核心工序进度与物理指示灯状态
  @State processes: ProcessStep[] = []
  @State indicators: LineIndicator[] = []

  // 报警
  @State alarms: AlarmItem[] = [
    { id: 'A001', type: '温度超限', time: Date.now() - 60000,
      location: '温控区', level: '高', status: '未确认' },
    { id: 'A002', type: '物料缺失', time: Date.now() - 120000,
      location: '上料区', level: '中', status: '已确认' }
  ]
  @State filterLevel: string = '全部'
  @State tempHigh: number = 33
  @State tempLow: number = 22
  @State humiHigh: number = 75
  @State humiLow: number = 45

  //订单
  @State orders: OrderItem[] = []
  // 扫码输入
  @State scanCode: string = ''
  // 产品名
  @State newProduct: string = ''
  // 数量
  @State newQty: string = '10'
  // 优先级
  @State newPriority: string = '中'

  //方法
  //上次报警的时间
  private lastAlarmTime: Map<string, number> = new Map()
  //数据源：现在用模拟数据，以后换成真实 MQTT 服务
  private dataService: IDataService = new MockDataService()
  //历史数据仓储：采集即落库，支持最近1小时回看与导出（模块三硬指标）
  private historyStore: HistoryStore = HistoryStore.getInstance()
  @State historyPoints: HistoryPoint[] = []
  @State historyRange: number = 60
  private historyTick: number = 0
  //国密服务（SM2/SM3/SM4），后续 MQTT 报文加密走它
  private cryptoService: CryptoService = CryptoService.getInstance()
  @State cryptoResults: CryptoCheckResult[] = []
  //这是里面的图
  private chartSettings: RenderingContextSettings = new RenderingContextSettings(true)
  private gaugeSettings: RenderingContextSettings = new RenderingContextSettings(true)
  //canvas绘图上下文
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.chartSettings)
  private gaugeCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.gaugeSettings)
  //历史曲线画布
  private historySettings: RenderingContextSettings = new RenderingContextSettings(true)
  private historyCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.historySettings)
//开始,回调函数，提供窗口
  aboutToAppear() {
    // 数据来源：现在用模拟数据，以后换成真实 MQTT 服务即
    this.dataService.onData((d: SensorData) => {
      this.temp = d.temp
      this.humi = d.humi
      this.sensor = d.sensor

      // 落库：写入 RelationalStore，供"最近1小时回看"与 CSV 导出使用
      const pt: HistoryPoint = { ts: Date.now(), temp: d.temp, humi: d.humi, sensor: d.sensor }
      this.historyStore.insert(pt)
        .catch((err: Error) => console.error(`历史数据写入失败: ${err.message}`))

      // 历史曲线增量更新：新点追加 + 剔除窗口外的旧点，每 5 秒重画一次
      if (this.historyPoints.length > 0) {
        this.historyTick++
        const cut: number = Date.now() - this.historyRange * 60 * 1000
        this.historyPoints = this.historyPoints.filter((p: HistoryPoint) => p.ts >= cut)
        this.historyPoints.push(pt)
        if (this.historyTick % 5 === 0) this.drawHistoryChart()
      }

      // shift和push：超过30个就删最老的，保留最近30个
      this.tempHistory.push(this.temp)
      this.humiHistory.push(this.humi)
      if (this.tempHistory.length > 30) this.tempHistory.shift()
      if (this.humiHistory.length > 30) this.humiHistory.shift()

      // 报警检测
      if (this.temp > this.tempHigh) {
        this.addAlarm('温度超限', '温控区', '高')
      } else if (this.temp < this.tempLow) {
        this.addAlarm('温度过低', '温控区', '中')
      }
      if (this.humi > this.humiHigh) {
        this.addAlarm('湿度过高', '湿度区', '中')
      } else if (this.humi < this.humiLow) {
        this.addAlarm('湿度过低', '湿度区', '低')
      }

      // 订单进度，增加
      this.tickOrders()
      // 画图
      this.drawChart()
      this.drawGauge()
    })

    // 控制指令下发后，服务器回推产线状态（Mock 直接回调）
    this.dataService.onCommand((cmd: string, status: string) => {
      this.lineStatus = status
    })

    // 工序进度 + 物理指示灯状态（真实环境由服务器推送，Mock 本地模拟）
    this.dataService.onLineState((s: LineState) => {
      this.processes = s.processes
      this.indicators = s.indicators
    })

    this.dataService.start()
    // 初始化历史库并默认查一次"最近1小时"
    this.initHistory()
  }

  // 初始化历史库：建表 → 清掉2小时前的旧数据 → 默认查最近1小时
  async initHistory() {
    try {
      await this.historyStore.init(getContext(this))
      await this.historyStore.purgeOlderThan(Date.now() - 2 * 60 * 60 * 1000)
      await this.queryHistory(this.historyRange)
      this.logs.unshift(`${this.now()} 历史数据模块已就绪`)
    } catch (e) {
      this.logs.unshift(`${this.now()} 历史库初始化失败：${e.message}`)
    }
  }

//关闭时，就是我们的app关了，这个也要关了
  aboutToDisappear() {
    this.dataService.stop()
  }

  //订单方法

  // 每秒钟生产中的订单进度+5，当进度变成100时则变成已完成
  //map就是遍历
  tickOrders() {
    this.orders = this.orders.map((o: OrderItem): OrderItem => {
      if (o.status !== '生产中') return o
      let p = o.progress + 5
      if (p >= 100) {
        //这个&{}，用了这个，就不用那种''+''+'',这种形式了
        //unshift和push相反，插入开头
        this.logs.unshift(`${this.now()} 订单 ${o.id} 已完成`)
        return {
          id: o.id, product: o.product, qty: o.qty, priority: o.priority,
          status: '已完成', createTime: o.createTime,
          finishTime: Date.now(), progress: 100
        }
      }
      return {
        id: o.id, product: o.product, qty: o.qty, priority: o.priority,
        status: o.status, createTime: o.createTime,
        finishTime: o.finishTime, progress: p
      }
    })
  }

  // 新增订单
  addOrder() {
    if (this.newProduct.trim() === '') {
      //弹窗提示
      AlertDialog.show({ title: '提示', message: '请输入产品名称',
        confirm: { value: '知道了', action: () => {} } })
      return
    }
    const qty = parseInt(this.newQty)
    if (Number.isNaN(qty) || qty <= 0) {
      AlertDialog.show({ title: '提示', message: '数量要大于 0',
        confirm: { value: '知道了', action: () => {} } })
      return
    }
    //获取当前时间
    const now = Date.now()
    //插入新订单，
    this.orders.unshift({
      //以下为新订单的对象
      id: `ORD${now}`,
      product: this.newProduct.trim(),
      qty: qty,
      priority: this.newPriority,
      status: '待生产',
      createTime: now,
      finishTime: 0,
      progress: 0
    })
    //插入新日志
    this.logs.unshift(`${this.now()} 新增订单 ${this.newProduct}×${qty}`)
    //重置表单
    this.newProduct = ''
    this.newQty = '10'
    this.newPriority = '中'
  }

  // 扫码方法，模拟扫码枪输入订单号的时候，回车触发
  handleScan() {
    const code = this.scanCode.trim()
    if (code === '') return//空
    // 模拟，扫码后按规则生成一个订单
    //这个也有时间戳
    const now = Date.now()
    //插入的新订单
    this.orders.unshift({
      id: code,
      product: '扫码产品-' + code.slice(-4),
      qty: 20,
      priority: '中',
      status: '待生产',
      createTime: now,
      finishTime: 0,
      progress: 0
    })
    //插入的新日志
    this.logs.unshift(`${this.now()} 扫码下单 ${code}`)
    this.scanCode = ''
  }

  // 开始生产
  startOrder(id: string) {
    // 使用 map 遍历订单数组，生成新数组
    this.orders = this.orders.map((o: OrderItem): OrderItem => {
      //如果当前订单的 id 与传入的 id 不相等，直接返回原对象（不修改）
      if (o.id !== id) {
        return o
      }
      // 如果匹配到目标订单，返回一个新对象，只修改 status 字段
      return {
        id: o.id,
        product: o.product,
        qty: o.qty,
        priority: o.priority,
        // 状态从原值改为'生产中'
        status: '生产中',
        createTime: o.createTime,
        finishTime: o.finishTime,
        progress: o.progress
      }
    })
    // 向日志插入
    this.logs.unshift(`${this.now()} 订单 ${id} 开始生产`)
  }

  // 确认完成
  finishOrder(id: string) {
    AlertDialog.show({
      title: '二次确认',
      message: `确认订单 ${id} 已完成？`,
      //第一个按钮
      primaryButton: { value: '取消', action: () => {} },
      //第二个按钮
      secondaryButton: {
        value: '确认',
        action: () => {
          this.orders = this.orders.map((o: OrderItem): OrderItem => {
            if (o.id !== id) return o
            return {
              id: o.id, product: o.product, qty: o.qty, priority: o.priority,
              status: '已完成', createTime: o.createTime,
              finishTime: Date.now(), progress: 100
            }
          })
          this.logs.unshift(`${this.now()} 订单 ${id} 确认完成`)
        }
      }
    })
  }

  // 删除订单
  deleteOrder(id: string) {
    this.orders = this.orders.filter((o: OrderItem) => o.id !== id)
    this.logs.unshift(`${this.now()} 删除订单 ${id}`)
  }

  // 报警方法
  addAlarm(type: string, location: string, level: string) {
    const now = Date.now()
    //??0确保第一次获取时返回0
    const last = this.lastAlarmTime.get(type) ?? 0
    if (now - last < 8000) return
    this.lastAlarmTime.set(type, now)
    this.alarms.unshift({
      id: `A${now}`, type: type, time: now,
      location: location, level: level, status: '未确认'
    })
    //pop删除最旧的记录
    if (this.alarms.length > 30) this.alarms.pop()
  }
//确认报警
  confirmAlarm(id: string): void {
    this.alarms = this.alarms.map((a: AlarmItem): AlarmItem =>
    a.id === id ? {
      // 匹配到目标告警时，保留原有字段，只有 status 改为 '已确认'
      id: a.id, type: a.type, time: a.time,
      location: a.location, level: a.level, status: '已确认'
    } : a
    )
    this.logs.unshift(`${this.now()} 确认报警 ${id}`)
  }
//筛选
  getFilteredAlarms(): AlarmItem[] {
    if (this.filterLevel === '全部') return this.alarms
    return this.alarms.filter(a => a.level === this.filterLevel)
  }

  // ============ 历史数据方法（模块三：最近1小时回看 / 对比 / 导出） ============

  // 查询最近 N 分钟，刷新曲线与统计
  async queryHistory(minutes: number) {
    this.historyRange = minutes
    try {
      const list = await this.historyStore.queryLastMinutes(minutes)
      this.historyPoints = list
      this.drawHistoryChart()
      this.logs.unshift(`${this.now()} 查询最近${minutes}分钟：${list.length}条`)
    } catch (e) {
      this.logs.unshift(`${this.now()} 历史查询失败：${e.message}`)
    }
  }

  // 抽稀：1小时3600个点没必要全画，均匀取样到 max 个
  private downSample(src: HistoryPoint[], max: number): HistoryPoint[] {
    if (src.length <= max) return src
    const step: number = src.length / max
    const out: HistoryPoint[] = []
    for (let i = 0; i < max; i++) {
      out.push(src[Math.floor(i * step)])
    }
    return out
  }

  // 历史统计：条数 + 温湿度极值 + 均值
  private historyStat(): string {
    const n = this.historyPoints.length
    if (n === 0) return '暂无数据'
    let sumT = 0, sumH = 0
    let minT = this.historyPoints[0].temp, maxT = this.historyPoints[0].temp
    let minH = this.historyPoints[0].humi, maxH = this.historyPoints[0].humi
    for (const p of this.historyPoints) {
      sumT += p.temp
      sumH += p.humi
      if (p.temp < minT) minT = p.temp
      if (p.temp > maxT) maxT = p.temp
      if (p.humi < minH) minH = p.humi
      if (p.humi > maxH) maxH = p.humi
    }
    return `${n}条 | 温度 ${minT.toFixed(1)}~${maxT.toFixed(1)}°C 均${(sumT / n).toFixed(1)} ` +
      `| 湿度 ${minH.toFixed(1)}~${maxH.toFixed(1)}% 均${(sumH / n).toFixed(1)}`
  }

  // 历史曲线：温度/湿度双线，量程自适应
  drawHistoryChart() {
    const w = this.historyCtx.width
    const h = this.historyCtx.height
    if (w === 0 || h === 0) return
    this.historyCtx.clearRect(0, 0, w, h)
    this.historyCtx.strokeStyle = '#EEEEEE'
    this.historyCtx.lineWidth = 1
    for (let i = 0; i <= 4; i++) {
      const y = (h / 4) * i
      this.historyCtx.beginPath()
      this.historyCtx.moveTo(0, y)
      this.historyCtx.lineTo(w, y)
      this.historyCtx.stroke()
    }
    if (this.historyPoints.length < 2) {
      this.historyCtx.fillStyle = '#999999'
      this.historyCtx.font = '13px sans-serif'
      this.historyCtx.textAlign = 'center'
      this.historyCtx.fillText('暂无历史数据，点上方按钮查询', w / 2, h / 2)
      return
    }
    const pts = this.downSample(this.historyPoints, 150)
    let minT = pts[0].temp, maxT = pts[0].temp
    let minH = pts[0].humi, maxH = pts[0].humi
    for (const p of pts) {
      if (p.temp < minT) minT = p.temp
      if (p.temp > maxT) maxT = p.temp
      if (p.humi < minH) minH = p.humi
      if (p.humi > maxH) maxH = p.humi
    }
    // 防除零：量程过窄时上下各留 0.5
    if (maxT - minT < 1) { maxT = maxT + 0.5; minT = minT - 0.5 }
    if (maxH - minH < 1) { maxH = maxH + 0.5; minH = minH - 0.5 }

    const stepX = w / (pts.length - 1)
    //温度线
    this.historyCtx.strokeStyle = '#FF6600'
    this.historyCtx.lineWidth = 2
    this.historyCtx.beginPath()
    for (let i = 0; i < pts.length; i++) {
      const x = stepX * i
      const y = h - ((pts[i].temp - minT) / (maxT - minT)) * h
      if (i === 0) this.historyCtx.moveTo(x, y)
      else this.historyCtx.lineTo(x, y)
    }
    this.historyCtx.stroke()
    //湿度线
    this.historyCtx.strokeStyle = '#3388FF'
    this.historyCtx.beginPath()
    for (let i = 0; i < pts.length; i++) {
      const x = stepX * i
      const y = h - ((pts[i].humi - minH) / (maxH - minH)) * h
      if (i === 0) this.historyCtx.moveTo(x, y)
      else this.historyCtx.lineTo(x, y)
    }
    this.historyCtx.stroke()
    //图例 + 起止时间
    this.historyCtx.font = '12px sans-serif'
    this.historyCtx.textAlign = 'left'
    this.historyCtx.fillStyle = '#FF6600'
    this.historyCtx.fillText('— 温度', 8, 14)
    this.historyCtx.fillStyle = '#3388FF'
    this.historyCtx.fillText('— 湿度', 70, 14)
    this.historyCtx.fillStyle = '#888888'
    this.historyCtx.fillText(this.formatTime(pts[0].ts), 8, h - 6)
    this.historyCtx.textAlign = 'right'
    this.historyCtx.fillText(this.formatTime(pts[pts.length - 1].ts), w - 8, h - 6)
  }

  // ============ 国密自检（SM2 / SM3 / SM4，合规性 5 分） ============

  // 跑一遍三种算法，结果直接显示在界面上，答辩可现场演示
  async runCryptoTest() {
    const list = await this.cryptoService.selfTest()
    this.cryptoResults = list
    let pass = 0
    for (const r of list) {
      if (r.ok) pass++
    }
    this.logs.unshift(`${this.now()} 国密自检：${pass}/${list.length} 项通过`)
  }

  // 演示一条控制指令的完整加密链路：SM4 加密 + SM3 摘要
  async demoEncryptCommand() {
    try {
      if (!this.cryptoService.ready()) {
        await this.cryptoService.initSessionKey()
      }
      const payload: string = JSON.stringify({ cmd: 'START', line: 1, ts: Date.now() })
      const cipher = await this.cryptoService.sm4Encrypt(payload)
      const digest = await this.cryptoService.sm3Digest(payload)
      this.logs.unshift(`${this.now()} 明文= ${payload}`)
      this.logs.unshift(`${this.now()} SM4密文= ${cipher.length}字节（联调后随报文发送）`)
      this.logs.unshift(`${this.now()} SM3摘要= ${digest.slice(0, 16)}…`)
    } catch (e) {
      this.logs.unshift(`${this.now()} 国密加解密失败：${e.message}`)
    }
  }

  // JSON 报文国密封装往返演示：明文 JSON → 信封 → 解封 → 还原（答辩重点演示）
  async demoJsonEnvelope() {
    try {
      const plain = ProtocolService.buildCommand('START', 'operator01')
      const envelope = await ProtocolService.seal(plain)
      const envObj = JSON.parse(envelope) as Record<string, string>
      const decoded = await ProtocolService.open(envelope)
      const msg = ProtocolService.parseCommand(decoded)
      this.logs.unshift(`${this.now()} 明文报文= ${plain}`)
      this.logs.unshift(`${this.now()} 信封= {alg:${envObj['alg']}, iv:${String(envObj['iv']).slice(0, 8)}…, payload:${String(envObj['payload']).length}B, sign:${String(envObj['sign']).slice(0, 8)}…}`)
      this.logs.unshift(`${this.now()} 解封还原= ${decoded}（msgId ${msg.msgId} 一致）`)
    } catch (e) {
      this.logs.unshift(`${this.now()} JSON信封往返失败：${e.message}`)
    }
  }

  // 导出当前查询到的历史数据为 CSV
  async exportHistoryCsv() {
    if (this.historyPoints.length === 0) {
      AlertDialog.show({ title: '提示', message: '请先查询历史数据再导出',
        confirm: { value: '知道了', action: () => {} } })
      return
    }
    try {
      const dir = getContext(this).filesDir
      const filePath = dir + '/history_' + this.historyRange + 'min.csv'
      let content = '时间,温度,湿度,光电传感器\n'
      for (const p of this.historyPoints) {
        content += `${this.formatTime(p.ts)},${p.temp},${p.humi},${p.sensor ? '触发' : '未触发'}\n`
      }
      const file = fs.openSync(filePath,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC)
      fs.writeSync(file.fd, content)
      fs.closeSync(file)
      this.logs.unshift(`${this.now()} 导出历史CSV成功：${filePath}`)
      AlertDialog.show({
        title: '导出成功',
        message: `共 ${this.historyPoints.length} 条\n` + filePath,
        confirm: { value: '知道了', action: () => {} }
      })
    } catch (e) {
      this.logs.unshift(`${this.now()} 导出失败：${e.message}`)
    }
  }

  // 图表方法
  //折线图
  drawChart() {
    //宽
    const w = this.ctx.width
    //高
    const h = this.ctx.height
    if (w === 0 || h === 0) return
    //清除胡，准备重新绘图
    this.ctx.clearRect(0, 0, w, h)
    //描边的颜色
    this.ctx.strokeStyle = '#EEEEEE'
    this.ctx.lineWidth = 1
    //循环五次
    for (let i = 0; i <= 4; i++) {
      //y坐标，在画布上绘制五条水平浅灰色网格线
      const y = (h / 4) * i
      //新的
      this.ctx.beginPath()
      //将画笔移动到画布左边缘的 (0, y) 点
      this.ctx.moveTo(0, y)
      //从当前点画一条直线到右边缘 (w, y)
      this.ctx.lineTo(w, y)
      //描边
      this.ctx.stroke()
    }
//画不出来线，数据不够
    if (this.tempHistory.length < 2) return
    //每个点之间的水平间距，假设的最多30个点
    const stepX = w / 29
    //温度范围
    const minT = 20, maxT = 35
    //湿度范围
    const minH = 40, maxH = 80
//温度，橙色
    this.ctx.strokeStyle = '#FF6600'
    this.ctx.lineWidth = 2
    this.ctx.beginPath()
    for (let i = 0; i < this.tempHistory.length; i++) {
      const x = stepX * i

      const y = h - ((this.tempHistory[i] - minT) / (maxT - minT)) * h
      //移动
      if (i === 0) this.ctx.moveTo(x, y)
        //连线
      else this.ctx.lineTo(x, y)
    }
    //绘图
    this.ctx.stroke()
//湿度，蓝色
    this.ctx.strokeStyle = '#3388FF'
    this.ctx.beginPath()
    for (let i = 0; i < this.humiHistory.length; i++) {
      const x = stepX * i
      const y = h - ((this.humiHistory[i] - minH) / (maxH - minH)) * h
      if (i === 0) this.ctx.moveTo(x, y)
      else this.ctx.lineTo(x, y)
    }
    this.ctx.stroke()
//文字
    this.ctx.font = '12px sans-serif'
    this.ctx.textAlign = 'left'
    this.ctx.fillStyle = '#FF6600'
    this.ctx.fillText('— 温度', 8, 14)
    this.ctx.fillStyle = '#3388FF'
    this.ctx.fillText('— 湿度', 70, 14)
  }

  // 仪表盘
  drawGauge() {
    const w = this.gaugeCtx.width
    const h = this.gaugeCtx.height
    if (w === 0 || h === 0) return
    this.gaugeCtx.clearRect(0, 0, w, h)
    const cx = w / 2
    //y偏下方，因为表盘是上半圆
    const cy = h * 0.75
    //取宽高中较小值的55%
    const r = Math.min(w, h) * 0.55
//灰色
    this.gaugeCtx.strokeStyle = '#DDDDDD'
    this.gaugeCtx.lineWidth = 12
    this.gaugeCtx.beginPath()
    //从 180° 到 360°
    this.gaugeCtx.arc(cx, cy, r, Math.PI, Math.PI * 2)
    this.gaugeCtx.stroke()
//计算比例，然后限制范围
    const minT = 20, maxT = 35
    //0~1
    let ratio = (this.temp - minT) / (maxT - minT)
    //最低
    if (ratio < 0) ratio = 0
    //最高
    if (ratio > 1) ratio = 1
    //结束角度
    const endAngle = Math.PI + Math.PI * ratio
//进度弧，按温度变色
    this.gaugeCtx.strokeStyle = ratio < 0.5 ? '#00AA00' :
      ratio < 0.8 ? '#FFAA00' : '#FF0000'
    this.gaugeCtx.lineWidth = 12
    this.gaugeCtx.beginPath()
    this.gaugeCtx.arc(cx, cy, r, Math.PI, endAngle)
    this.gaugeCtx.stroke()
//指针
    const angle = Math.PI + Math.PI * ratio // 在组件中定义常量
    const px = cx + Math.cos(angle) * (r - 18)
    const py = cy + Math.sin(angle) * (r - 18)
    this.gaugeCtx.strokeStyle = '#333333'
    this.gaugeCtx.lineWidth = 3
    this.gaugeCtx.beginPath()
    this.gaugeCtx.moveTo(cx, cy)
    this.gaugeCtx.lineTo(px, py)
    this.gaugeCtx.stroke()
//轴心
    this.gaugeCtx.fillStyle = '#333333'
    this.gaugeCtx.beginPath()
    this.gaugeCtx.arc(cx, cy, 5, 0, Math.PI * 2)
    this.gaugeCtx.fill()
    this.gaugeCtx.fillStyle = '#333333'
    //温度文字
    this.gaugeCtx.font = '16px sans-serif'
    this.gaugeCtx.textAlign = 'center'
    this.gaugeCtx.fillText(`${this.temp}°C`, cx, cy - 15)
  }
//时间戳
  private formatTime(ts: number): string {
    const t = new Date(ts)
    const pad = (n: number) => n.toString().padStart(2, '0')
    return `${pad(t.getHours())}:${pad(t.getMinutes())}:${pad(t.getSeconds())}`
  }
//async写文件的时候要用到
  //导出CSV文件
  async exportCsv() {
   //我将用到try和catch，保险起见，我相信你们知道这里在干啥
    try {
      //拿到应用的私有文件目录路径
      const dir = getContext(this).filesDir
      //拼接成sensor_data.csv的完整路径
      const filePath = dir + '/sensor_data.csv'
      //csv表头
      let content = '时间,温度,湿度\n'
      //时间戳
      const now = new Date().getTime()
      //第i条距离现在多少毫秒
      for (let i = 0; i < this.tempHistory.length; i++) {
        const ts = now - (this.tempHistory.length - 1 - i) * 1000//每秒
        content += `${this.formatTime(ts)},${this.tempHistory[i]},${this.humiHistory[i]}\n`
      }
      const file = fs.openSync(filePath,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC)
      fs.writeSync(file.fd, content)
      fs.closeSync(file)
      this.logs.unshift(`${this.now()} 导出CSV成功：${filePath}`)
      AlertDialog.show({
        title: '导出成功',
        message: '文件已保存到：\n' + filePath,
        confirm: { value: '知道了', action: () => {} }
      })
    } catch (e) {
      this.logs.unshift(`${this.now()} 导出失败：${e.message}`)
    }
  }
//状态颜色
  private statusColor(): Color {
    if (this.lineStatus === '运行中') return Color.Green
    if (this.lineStatus === '停止') return Color.Gray
    return Color.Red
  }
//时间补零
  private now(): string {
    const t = new Date()
    const pad = (n: number) => n.toString().padStart(2, '0')
    return `${pad(t.getHours())}:${pad(t.getMinutes())}:${pad(t.getSeconds())}`
  }
//第二次确认
  confirmAndDo(cmd: string, newStatus: string) {
    AlertDialog.show({
      title: '二次确认',
      message: `确认要执行【${cmd}】吗`,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: '确认',
        action: () => {
          // 真实接入：指令加密后发 MQTT，由服务器校验后下 PLC；Mock 直接回调更新状态
          this.dataService.sendCommand(cmd, newStatus)
          this.logs.unshift(`${this.now()} 操作员 执行【${cmd}】结果:成功`)
        }
      }
    })
  }

  // 工序状态配色
  private stepColor(status: string): Color {
    if (status === '已完成') return Color.Green
    if (status === '执行中') return Color.Orange
    return Color.Gray
  }

  // 指示灯配色：熄灭为灰，点亮按灯色（运行绿 / 故障红 / 复位橙 / 停止红）
  private indicatorColor(item: LineIndicator): Color {
    if (!item.on) return Color.Gray
    if (item.name.includes('运行')) return Color.Green
    if (item.name.includes('故障')) return Color.Red
    if (item.name.includes('复位')) return Color.Orange
    return Color.Red
  }

  build() {
    //可以滚动
    Scroll() {
      //间隔为10
      Column({ space: 10 }) {
        Text('产线监控')
          .fontSize(26)
          .fontWeight(FontWeight.Bold)

        Text(`产线状态 ${this.lineStatus}`)
          .fontSize(20)
          .fontColor(this.statusColor())

        Text(`温度 ${this.temp}°C   湿度 ${this.humi}%`)
          .fontSize(16)
        Text(`传感器:${this.sensor ? '触发' : '未触发'}`)
          .fontSize(16)
          .fontColor(this.sensor ? Color.Orange : Color.Gray)
//横着的三个按钮，间隔10
        Row({ space: 10 }) {
          Button('启动')
            .backgroundColor(Color.Green)
            .fontSize(14)
            .onClick(() => this.confirmAndDo('启动', '运行中'))
          Button('停止')
            .backgroundColor(Color.Gray)
            .fontSize(14)
            .onClick(() => this.confirmAndDo('停止', '停止'))
          Button('复位')
            .backgroundColor(Color.Orange)
            .fontSize(14)
            .onClick(() => this.confirmAndDo('复位', '复位中'))
        }

        // 模块一：核心工序（上料/装配/检测/打包/入库）执行进度
        Text('核心工序进度')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
        Column({ space: 6 }) {
          ForEach(this.processes, (p: ProcessStep) => {
            Row({ space: 8 }) {
              Text(p.name)
                .fontSize(14)
                .width(48)
              Progress({ value: p.progress, total: 100, type: ProgressType.Linear })
                .width('58%')
                .height(12)
                .color(this.stepColor(p.status))
              Text(`${p.progress}%`)
                .fontSize(12)
                .width(40)
              Text(p.status)
                .fontSize(12)
                .fontColor(this.stepColor(p.status))
            }
            .width('100%')
          }, (p: ProcessStep) => p.name)
        }
        .width('100%')
        .padding(8)
        .border({ width: 1, color: Color.Gray })

        // 模块一：与物理产线指示灯同步
        Text('物理产线指示灯')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
        Row({ space: 14 }) {
          ForEach(this.indicators, (item: LineIndicator) => {
            Column({ space: 4 }) {
              Circle({ width: 22, height: 22 })
                .fill(this.indicatorColor(item))
                .stroke(item.on ? Color.Black : Color.Gray)
                .strokeWidth(1)
              Text(item.name)
                .fontSize(12)
              Text(item.on ? '亮' : '灭')
                .fontSize(11)
                .fontColor(item.on ? this.indicatorColor(item) : Color.Gray)
            }
          }, (item: LineIndicator) => item.name)
        }
        .width('100%')
        .justifyContent(FlexAlign.Start)
        .padding(8)
        .border({ width: 1, color: Color.Gray })

        Text('温度仪表盘')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
        Canvas(this.gaugeCtx)
          .width(200)
          .height(120)
          .backgroundColor(Color.White)
          //准备好时，就执行画图
          .onReady(() => { this.drawGauge() })

        Text('温湿度趋势（最近 30 秒）')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
        Canvas(this.ctx)
          .width('90%')
          .height(130)
          .backgroundColor(Color.White)
          .border({ width: 1, color: Color.Gray })
          .onReady(() => { this.drawChart() })

        Button('导出 CSV')
          .fontSize(14)
          .backgroundColor(Color.Blue)
          .onClick(() => this.exportCsv())

        // 历史数据回看（模块三硬指标：最近1小时）
        Divider()
          .margin({ top: 12, bottom: 4 })
        Text('历史数据回看')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)

        Row({ space: 8 }) {
          ForEach([10, 30, 60],
            (m: number) => {
              Button(`${m}分钟`)
                .fontSize(13)
                .backgroundColor(this.historyRange === m ? Color.Blue : Color.Gray)
                .onClick(() => { this.queryHistory(m) })
            },
            (m: number) => m.toString()
          )
        }

        Text(`最近 ${this.historyRange} 分钟 · ${this.historyStat()}`)
          .fontSize(12)
          .fontColor(Color.Gray)

        Canvas(this.historyCtx)
          .width('90%')
          .height(150)
          .backgroundColor(Color.White)
          .border({ width: 1, color: Color.Gray })
          .onReady(() => { this.drawHistoryChart() })

        Button('导出历史 CSV')
          .fontSize(14)
          .backgroundColor(Color.Blue)
          .onClick(() => { this.exportHistoryCsv() })

        // 国密自检（SM2 / SM3 / SM4）
        Divider()
          .margin({ top: 12, bottom: 4 })
        Text('国密算法自检')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)

        Row({ space: 8 }) {
          Button('运行自检')
            .fontSize(13)
            .backgroundColor(Color.Blue)
            .onClick(() => { this.runCryptoTest() })
          Button('加密一条指令')
            .fontSize(13)
            .backgroundColor(Color.Green)
            .onClick(() => { this.demoEncryptCommand() })
          Button('JSON信封往返')
            .fontSize(13)
            .backgroundColor(Color.Orange)
            .onClick(() => { this.demoJsonEnvelope() })
        }

        Column({ space: 4 }) {
          ForEach(this.cryptoResults,
            (r: CryptoCheckResult) => {
              Row({ space: 6 }) {
                Text(r.ok ? '通过' : '失败')
                  .fontSize(12)
                  .fontColor(r.ok ? Color.Green : Color.Red)
                  .width(40)
                Text(r.name)
                  .fontSize(13)
                  .width(110)
                Text(r.detail)
                  .fontSize(11)
                  .fontColor(Color.Gray)
                  .layoutWeight(1)
              }
              .width('100%')
            },
            (r: CryptoCheckResult) => r.name
          )
        }
        .width('90%')
        .padding(8)
        .border({ width: 1, color: Color.Gray })
        .borderRadius(8)

        //报警管理
        //分隔线
        Divider()
          .margin({ top: 12, bottom: 4 })
        Text('报警管理')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)

        Text('报警阈值配置')
          .fontSize(14)
          .fontColor(Color.Gray)
        Row({ space: 6 }) {
          Text(`温度上限 ${this.tempHigh}°C`)
            .fontSize(13)
            .width(120)
          //滑块
          Slider({ value: this.tempHigh, min: 28, max: 40, step: 1 })
            .width(180)
            //回调，需要调用的函数
            .onChange((value: number, mode: SliderChangeMode) => {
              //温度上限更新
              this.tempHigh = value
            })
        }
        Row({ space: 6 }) {
          Text(`温度下限 ${this.tempLow}°C`)
            .fontSize(13)
            .width(120)
          Slider({ value: this.tempLow, min: 15, max: 24, step: 1 })
            .width(180)
            .onChange((value: number, mode: SliderChangeMode) => {
              this.tempLow = value
            })
        }
        Row({ space: 6 }) {
          Text(`湿度上限 ${this.humiHigh}%`)
            .fontSize(13)
            .width(120)
          Slider({ value: this.humiHigh, min: 60, max: 90, step: 1 })
            .width(180)
            .onChange((value: number, mode: SliderChangeMode) => {
              this.humiHigh = value
            })
        }
        Row({ space: 6 }) {
          Text(`湿度下限 ${this.humiLow}%`)
            .fontSize(13)
            .width(120)
          Slider({ value: this.humiLow, min: 30, max: 60, step: 1 })
            .width(180)
            .onChange((value: number, mode: SliderChangeMode) => {
              this.humiLow = value
            })
        }

        Row({ space: 8 }) {
          ForEach(['全部', '高', '中', '低'],
            (lvl: string) => {
              Button(lvl)
                .fontSize(13)
                .backgroundColor(this.filterLevel === lvl ? Color.Blue : Color.Gray)
                .onClick(() => { this.filterLevel = lvl })
            },
            (lvl: string) => lvl
          )
        }
        .margin({ top: 6 })
//列表，可滚动
        List() {
          ForEach(this.getFilteredAlarms(),
            (item: AlarmItem) => {
              ListItem() {
                Row({ space: 8 }) {
                  Column({ space: 2 }) {
                    Text(`[${item.level}] ${item.type}`)
                      .fontSize(14)
                      .fontColor(item.level === '高' ? Color.Red :
                        item.level === '中' ? Color.Orange : Color.Gray)
                    Text(`${this.formatTime(item.time)}  ${item.location}`)
                      .fontSize(12)
                      .fontColor(Color.Gray)
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)

                  if (item.status === '未确认') {
                    Button('确认')
                      .fontSize(12)
                      .backgroundColor(Color.Red)
                      .onClick(() => this.confirmAlarm(item.id))
                  } else {
                    Text('已确认')
                      .fontSize(12)
                      .fontColor(Color.Green)
                  }
                }.width('100%')
                .padding(8)
              }
            },
            (item: AlarmItem) => item.id
          )
        }
        .height(200).width('90%')
        .border({ width: 1, color: Color.Gray })
        .borderRadius(8)

        // 订单管理
        //分隔线
        Divider()
          .margin({ top: 12, bottom: 4 })
        Text('订单管理')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)

        // 扫码框
        Text('扫码下单')
          .fontSize(14)
          .fontColor(Color.Gray)
        //输入
        TextInput({ text: this.scanCode, placeholder: '扫码枪扫描或手动输入订单号' })
          .width('90%')
          .onChange((v: string) => { this.scanCode = v })
          //回车，上面方法注释也有
          .onSubmit(() => { this.handleScan() })
        Button('提交扫码')
          .fontSize(13)
          .backgroundColor(Color.Blue)
          .onClick(() => this.handleScan())

        // 手动录入
        Text('手动录入订单')
          .fontSize(14)
          .fontColor(Color.Gray)
          .margin({ top: 8 })
        TextInput({ text: this.newProduct, placeholder: '产品名称' })
          .width('90%')
          //输入内容v存入newProduct
          .onChange((v: string) => { this.newProduct = v })
        Row({ space: 8 }) {
          TextInput({ text: this.newQty, placeholder: '数量' })
            .width(100)
            //只能输入数字
            .type(InputType.Number)
            .onChange((v: string) => { this.newQty = v })

          Row({ space: 4 }) {
            ForEach(['高', '中', '低'],
              (p: string) => {
                Button(p)
                  .fontSize(12)
                  .backgroundColor(this.newPriority === p ? Color.Blue : Color.Gray)
                  .onClick(() => { this.newPriority = p })
              },
              (p: string) => p
            )
          }
        }

        Button('新增订单')
          .fontSize(14)
          .backgroundColor(Color.Green)
          .onClick(() => this.addOrder())

        // 订单列表
        List() {
          ForEach(this.orders,
            (o: OrderItem) => {
              ListItem() {
                Column({ space: 4 }) {
                  Row({ space: 8 }) {
                    Text(`[${o.priority}] ${o.product} ×${o.qty}`)
                      .fontSize(14)
                      .layoutWeight(1)
                    Text(o.status)
                      .fontSize(12)
                      .fontColor(o.status === '已完成' ? Color.Green :
                        o.status === '生产中' ? Color.Orange : Color.Gray)
                  }
                  Text(`编号：${o.id}`)
                    .fontSize(11)
                    .fontColor(Color.Gray)

                  // 进度条
                  Progress({ value: o.progress, total: 100, type: ProgressType.Linear })
                    .width('100%')

                  Row({ space: 8 }) {
                    if (o.status === '待生产') {
                      Button('开始生产')
                        .fontSize(12)
                        .backgroundColor(Color.Blue)
                        .onClick(() => this.startOrder(o.id))
                    }
                    if (o.status === '生产中') {
                      Button('确认完成')
                        .fontSize(12)
                        .backgroundColor(Color.Green)
                        .onClick(() => this.finishOrder(o.id))
                    }
                    Button('删除')
                      .fontSize(12)
                      .backgroundColor(Color.Red)
                      .onClick(() => this.deleteOrder(o.id))
                  }
                }
                .width('100%')
                .padding(8)
                .alignItems(HorizontalAlign.Start)
              }
            },
            (o: OrderItem) => o.id
          )
        }
        .height(260).width('90%')
        .border({ width: 1, color: Color.Gray })
        .borderRadius(8)
        //订单管理结束

        Text('操作日志').fontSize(16).fontWeight(FontWeight.Bold)

        List() {
          ForEach(this.logs, (item: string) => {
            ListItem() { Text(item).fontSize(13) }
          })
        }
        .height(90)
        .width('90%')
        .border({ width: 1, color: Color.Gray })
        .borderRadius(8)
      }
      .width('100%')
      .padding(10)
    }
  }
}
//出现多少千的数多指时间，毫秒，1000=1s，可以看懂什么意思就行
//后面犯懒了，因为感觉大家应该能懂
