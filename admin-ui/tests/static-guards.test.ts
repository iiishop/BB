import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

function sourceFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) return sourceFiles(path);
    return /\.(ts|vue|css|html)$/.test(path) ? [path] : [];
  });
}

const root = resolve(process.cwd(), 'src');
const files = sourceFiles(root);

function codeOnly(content: string): string {
  return content
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/(^|\s)\/\/.*$/gm, '');
}

describe('browser persistence and CSP guards', () => {
  it('never uses localStorage, sessionStorage or document.cookie for credentials', () => {
    for (const file of files) {
      const content = codeOnly(readFileSync(file, 'utf8'));
      expect(content, file).not.toMatch(/\blocalStorage\b/);
      expect(content, file).not.toMatch(/\bsessionStorage\b/);
      expect(content, file).not.toMatch(/document\.cookie/);
    }
  });

  it('does not rely on inline event handlers or v-html', () => {
    for (const file of files) {
      const content = codeOnly(readFileSync(file, 'utf8'));
      expect(content, file).not.toMatch(/\bv-html\b/);
      expect(content, file).not.toMatch(/\son[a-z]+="/);
    }
  });

  it('does not request external origins (self-only CSP)', () => {
    for (const file of files) {
      const content = codeOnly(readFileSync(file, 'utf8'));
      const external = content.match(/https?:\/\/(?!127\.0\.0\.1|localhost)[a-z0-9.-]+/gi) ?? [];
      expect(external, file).toEqual([]);
    }
  });

  it('uses a build base of /admin/ and a relative API prefix', () => {
    const vite = readFileSync(resolve(process.cwd(), 'vite.config.ts'), 'utf8');
    expect(vite).toContain("base: '/admin/'");
    const client = readFileSync(resolve(root, 'api/client.ts'), 'utf8');
    expect(client).toContain("const BASE = '/admin/api'");
    expect(client).not.toContain('http://');
    expect(client).not.toContain('https://');
  });
});
