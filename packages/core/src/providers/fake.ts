import type { ChatRequest, ChatResponse, LLMProviderAdapter, ProviderConfig } from './types';

/** 脚本化假 Provider：按队列返回预置响应，队列空时抛错（模拟调用失败），用于测试与 M0 骨架 */
export class FakeLLMAdapter implements LLMProviderAdapter {
  readonly requests: ChatRequest[] = [];
  private readonly queue: ChatResponse[] = [];

  constructor(responses: string[] = []) {
    for (const r of responses) this.queue.push({ text: r });
  }

  push(response: string): void {
    this.queue.push({ text: response });
  }

  async chat(req: ChatRequest, _cfg: ProviderConfig): Promise<ChatResponse> {
    this.requests.push(req);
    const next = this.queue.shift();
    if (!next) throw new Error('FakeLLMAdapter: 无预置响应（模拟调用失败）');
    return next;
  }
}
