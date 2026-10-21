import { cryptoFramework } from '@kit.CryptoArchitectureKit'
import { buffer } from '@kit.ArkTS'

// 国密加解密服务（SM2 / SM3 / SM4），基于系统自带的 cryptoFramework，不依赖组委会 SDK。
// 赛题要求：数据传输链路必须强制使用国密算法加密，明文传输视为严重违规。
//
// 真实通信时的用法：
//   发送：SM2 协商出 SM4 会话密钥 → JSON 报文用 SM4 加密 → SM3 做摘要/签名
//   接收：SM2 解密取出会话密钥 → SM4 解密 → SM3 摘要比对（完整性）
// 目前组委会接口协议还没下发，先做自检 demo，验证设备端国密能力可用。

// 自检结果：跑给你和评委看
export interface CryptoCheckResult {
  name: string
  ok: boolean
  detail: string
}

function toBlob(text: string): cryptoFramework.DataBlob {
  return { data: new Uint8Array(buffer.from(text, 'utf-8').buffer) }
}

function toText(data: Uint8Array): string {
  return buffer.from(data.buffer, data.byteOffset, data.byteLength).toString('utf-8')
}

function toHex(data: Uint8Array): string {
  let s = ''
  for (let i = 0; i < data.length; i++) {
    s += data[i].toString(16).padStart(2, '0')
  }
  return s
}

function genIv(): cryptoFramework.IvParamsSpec {
  const rand = cryptoFramework.createRandom()
  const blob: cryptoFramework.DataBlob = rand.generateRandomSync(16)
  const iv: cryptoFramework.IvParamsSpec = { algName: 'IvParamsSpec', iv: blob }
  return iv
}

export class CryptoService {
  private static instance: CryptoService = new CryptoService()
  private symKey: cryptoFramework.SymKey | null = null
  private iv: cryptoFramework.IvParamsSpec | null = null

  static getInstance(): CryptoService {
    return CryptoService.instance
  }

  // 生成 SM4 会话密钥 + 随机 IV。
  // Demo 阶段本地随机生成；正式联调时这里换成 SM2 协商下发的密钥。
  async initSessionKey(): Promise<void> {
    const generator = cryptoFramework.createSymKeyGenerator('SM4_128')
    this.symKey = await generator.generateSymKey()
    this.iv = genIv()
  }

  ready(): boolean {
    return this.symKey !== null && this.iv !== null
  }

  // SM4 对称加密（后续 MQTT payload 走这个）
  async sm4Encrypt(plain: string): Promise<Uint8Array> {
    const key = this.symKey
    const iv = this.iv
    if (key === null || iv === null) throw new Error('SM4 会话密钥未初始化')
    const cipher = cryptoFramework.createCipher('SM4_128|CBC|PKCS7')
    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, key, iv)
    const out = await cipher.doFinal(toBlob(plain))
    return out.data
  }

  // SM4 对称解密
  async sm4Decrypt(cipherData: Uint8Array): Promise<string> {
    const key = this.symKey
    const iv = this.iv
    if (key === null || iv === null) throw new Error('SM4 会话密钥未初始化')
    const decoder = cryptoFramework.createCipher('SM4_128|CBC|PKCS7')
    await decoder.init(cryptoFramework.CryptoMode.DECRYPT_MODE, key, iv)
    const out = await decoder.doFinal({ data: cipherData })
    return toText(out.data)
  }

  // SM3 摘要（完整性校验）
  async sm3Digest(text: string): Promise<string> {
    const md = cryptoFramework.createMd('SM3')
    await md.update(toBlob(text))
    const out = await md.digest()
    return toHex(out.data)
  }

  // SM2 签名 + 验签（身份认证 / 防篡改）
  async sm2SignVerify(text: string): Promise<boolean> {
    const generator = cryptoFramework.createAsyKeyGenerator('SM2_256')
    const keyPair = await generator.generateKeyPair()
    const signer = cryptoFramework.createSign('SM2_256|SM3')
    await signer.init(keyPair.priKey)
    const signature = await signer.sign(toBlob(text))
    const verifier = cryptoFramework.createVerify('SM2_256|SM3')
    await verifier.init(keyPair.pubKey)
    return verifier.verify(toBlob(text), signature)
  }

  // 一键自检：SM3 摘要 / SM4 加解密往返 / SM2 签名验签
  async selfTest(): Promise<CryptoCheckResult[]> {
    const results: CryptoCheckResult[] = []
    const sample = '{"cmd":"START","line":1,"ts":' + Date.now() + '}'
    try {
      await this.initSessionKey()
    } catch (e) {
      results.push({ name: 'SM4 密钥生成', ok: false, detail: `失败：${e.message}` })
      return results
    }

    // SM3
    try {
      const digest = await this.sm3Digest(sample)
      results.push({ name: 'SM3 摘要', ok: digest.length === 64, detail: `256bit：${digest.slice(0, 32)}…` })
    } catch (e) {
      results.push({ name: 'SM3 摘要', ok: false, detail: `失败：${e.message}` })
    }

    // SM4 加解密往返
    try {
      const cipher = await this.sm4Encrypt(sample)
      const back = await this.sm4Decrypt(cipher)
      results.push({
        name: 'SM4 加解密(CBC)',
        ok: back === sample,
        detail: `密文 ${cipher.length}B：${toHex(cipher.slice(0, 16))}… 还原${back === sample ? '一致' : '失败'}`
      })
    } catch (e) {
      results.push({ name: 'SM4 加解密(CBC)', ok: false, detail: `失败：${e.message}` })
    }

    // SM2 签名验签
    try {
      const ok = await this.sm2SignVerify(sample)
      results.push({ name: 'SM2 签名验签', ok: ok, detail: ok ? 'SM2_256|SM3 验签通过' : '验签不通过' })
    } catch (e) {
      results.push({ name: 'SM2 签名验签', ok: false, detail: `失败：${e.message}` })
    }

    return results
  }
}
