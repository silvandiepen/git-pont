import { HttpResponse, utf8ToBytes, type HttpClient, type HttpRequest } from "../src/index.js";

export type Handler = (request: HttpRequest) => HttpResponse | Promise<HttpResponse>;

export class MockHttpClient implements HttpClient {
  readonly calls: HttpRequest[] = [];
  constructor(private readonly handler: Handler) {}

  async send(request: HttpRequest): Promise<HttpResponse> {
    this.calls.push(request);
    return this.handler(request);
  }
}

export function jsonResponse(
  status: number,
  body: unknown,
  headers: Record<string, string> = {},
): HttpResponse {
  return new HttpResponse(
    status,
    { "content-type": "application/json", ...headers },
    utf8ToBytes(JSON.stringify(body)),
  );
}

export function countCalls(client: MockHttpClient, predicate: (r: HttpRequest) => boolean): number {
  return client.calls.filter(predicate).length;
}
