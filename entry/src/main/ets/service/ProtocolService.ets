import { CryptoService, bytesToHex, bytesToBase64, base64ToBytes } from './CryptoService'

// 数据交互协议（与 docs/技术文档.md 第四章一致，待组委会协议下发后对齐字段名）。
// 职责：把业务数据编成标准 JSON 报文 + 国密加密封装/解封。
// 真实接入时 MqttDataService 只负责收发字节，报文组装与加解密全部复用本类。

export const LINE_ID: number = 1

// ===== 明文报文结构（加密前）=====
export interface SensorPayload {
  temp: number    // 温度 °C
  humi: number    // 湿度 %
  photo: boolean  // 光电传感器触发状态
  status: string  // 产线状态
}

export interface AlarmPayload {
  alarmType: string   // TEMP_HIGH / TEMP_LOW / MATERIAL_MISSING / DEVICE_FAULT
  location: string    // 发生位置
  level: string       // HIGH / MEDIUM / LOW
  value: number       // 当前值
  threshold: number   // 阈值
}

export interface SensorMsg {
  msgId: string
  type: string    // SENSOR_DATA
  lineId: number
  ts: number
  data: SensorPayload
}

export interface CommandMsg {
  msgId: string
  type: string    // COMMAND
  lineId: number
  cmd: string     // START / STOP / RESET
  operator: string
  ts: number
}

export interface AlarmMsg {
  msgId: string
  type: string    // ALARM
  lineId: number
  ts: number
  data: AlarmPayload
}

// ===== 国密加密传输信封（加密后实际发送的 JSON）=====
export interface SecureEnvelope {
  alg: string      // 加密算法标识
  keyId: string    // 会话密钥标识
  iv: string       // SM4 IV（hex）
  payload: string  // base64(SM4(JSON))
  digest: string   // hex(SM3(JSON))
  sign: string     // base64(SM2签名(digest))
}

export class ProtocolService {
  // 8 位随机报文号，用于关联请求/响应与日志排查
  static msgId(): string {
    let s = ''
    for (let i = 0; i < 8; i++) {
      s += Math.floor(Math.random() * 16).toString(16)
    }
    return s
  }

  // ===== 报文组装（业务数据 → 明文 JSON）=====
  static buildSensor(temp: number, humi: number, photo: boolean, status: string): string {
    const msg: SensorMsg = {
      msgId: ProtocolService.msgId(),
      type: 'SENSOR_DATA',
      lineId: LINE_ID,
      ts: Date.now(),
      data: { temp: temp, humi: humi, photo: photo, status: status }
    }
    return JSON.stringify(msg)
  }

  static buildCommand(cmd: string, operator: string): string {
    const msg: CommandMsg = {
      msgId: ProtocolService.msgId(),
      type: 'COMMAND',
      lineId: LINE_ID,
      cmd: cmd,
      operator: operator,
      ts: Date.now()
    }
    return JSON.stringify(msg)
  }

  static buildAlarm(alarmType: string, location: string, level: string,
    value: number, threshold: number): string {
    const msg: AlarmMsg = {
      msgId: ProtocolService.msgId(),
      type: 'ALARM',
      lineId: LINE_ID,
      ts: Date.now(),
      data: {
        alarmType: alarmType,
        location: location,
        level: level,
        value: value,
        threshold: threshold
      }
    }
    return JSON.stringify(msg)
  }

  // ===== 报文解析（明文 JSON → 业务数据）=====
  static parseSensor(json: string): SensorMsg {
    return JSON.parse(json) as SensorMsg
  }

  static parseCommand(json: string): CommandMsg {
    return JSON.parse(json) as CommandMsg
  }

  static parseAlarm(json: string): AlarmMsg {
    return JSON.parse(json) as AlarmMsg
  }

  // ===== 国密封装（发送方向）=====
  // 明文 JSON → SM3 摘要 → SM2 签名摘要 → SM4 加密 → 信封 JSON
  static async seal(json: string): Promise<string> {
    const c = CryptoService.getInstance()
    await c.ensureKeys()
    const ivHex = CryptoService.randomIvHex()
    const digest = await c.sm3Digest(json)
    const cipher = await c.sm4EncryptIv(json, ivHex)
    const sign = await c.sm2Sign(digest)
    const env: SecureEnvelope = {
      alg: 'SM4_128_CBC_PKCS7',
      keyId: 'sm2-session-key-01',
      iv: ivHex,
      payload: bytesToBase64(cipher),
      digest: digest,
      sign: bytesToBase64(sign)
    }
    return JSON.stringify(env)
  }

  // ===== 国密解封（接收方向）=====
  // 信封 JSON → SM2 验签 → SM4 解密 → SM3 摘要比对 → 明文 JSON
  static async open(envelopeJson: string): Promise<string> {
    const env = JSON.parse(envelopeJson) as SecureEnvelope
    const c = CryptoService.getInstance()
    await c.ensureKeys()
    const sigOk = await c.sm2Verify(env.digest, base64ToBytes(env.sign))
    if (!sigOk) {
      throw new Error('SM2 验签失败，报文来源不可信')
    }
    const plain = await c.sm4DecryptIv(base64ToBytes(env.payload), env.iv)
    const digest = await c.sm3Digest(plain)
    if (digest !== env.digest) {
      throw new Error('SM3 摘要不一致，报文疑似被篡改')
    }
    return plain
  }
}
