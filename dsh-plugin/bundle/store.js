import {
  mkdir,
  open,
  readFile,
  readdir,
  rename,
  link,
  unlink,
} from "node:fs/promises";
import { resolve } from "node:path";
import { createHash, randomUUID } from "node:crypto";
export const digest = (value) =>
  createHash("sha256").update(JSON.stringify(value)).digest("hex");
export const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
export async function writeJson(path, value) {
  const temporary = path + ".tmp-" + randomUUID();
  const file = await open(temporary, "wx", 0o600);
  try {
    await file.writeFile(JSON.stringify(value) + "\n");
    await file.sync();
  } finally {
    await file.close();
  }
  await rename(temporary, path);
  const directory = await open(resolve(path, ".."), "r");
  try {
    await directory.sync();
  } finally {
    await directory.close();
  }
}
// Publish one owner capability without racing another freshly started instance.
export async function createJson(path, value) {
  const temporary = path + ".owner-" + randomUUID();
  await writeJson(temporary, value);
  try {
    await link(temporary, path);
  } catch (error) {
    if (error.code !== "EEXIST") throw error;
  } finally {
    await unlink(temporary);
  }
  const directory = await open(resolve(path, ".."), "r");
  try {
    await directory.sync();
  } finally {
    await directory.close();
  }
  return readJson(path);
}
export async function readJson(path, fallback) {
  try {
    return JSON.parse(await readFile(path, "utf8"));
  } catch (error) {
    if (error.code === "ENOENT") return fallback;
    throw error;
  }
}
export class Journal {
  constructor(root, identity) {
    this.root = resolve(
      root,
      "journal",
      digest([identity.account, identity.consumer_id]),
    );
    this.identity = identity;
    this.rows = new Map();
  }
  async open() {
    await mkdir(this.root, { recursive: true, mode: 0o700 });
    for (const name of (await readdir(this.root))
      .filter((x) => /^\d+-[a-f0-9]{64}\.json$/.test(x))
      .sort((a, b) => Number(a.split("-")[0]) - Number(b.split("-")[0]))) {
      const row = await readJson(resolve(this.root, name));
      if (
        row.version !== 1 ||
        row.account !== this.identity.account ||
        row.consumer !== this.identity.consumer_id ||
        ![
          "claimed",
          "prepared",
          "dispatching",
          "presented",
          "uncertain",
          "completed",
        ].includes(row.state)
      )
        throw new Error("Unsupported or corrupt BB journal");
      this.rows.set(row.key, row);
    }
  }
  async put(row) {
    if (
      !row.key ||
      !Number.isSafeInteger(row.position) ||
      row.position < 1 ||
      row.account !== this.identity.account ||
      row.consumer !== this.identity.consumer_id
    )
      throw new Error("Invalid BB journal write");
    const value = structuredClone({
      ...row,
      version: 1,
      revision: this.identity.binding_revision,
    });
    await writeJson(
      resolve(this.root, `${value.revision}-${value.key}.json`),
      value,
    );
    this.rows.set(value.key, value);
    return value;
  }
  get(key) {
    return structuredClone(this.rows.get(key));
  }
  list() {
    return [...this.rows.values()].map((x) => structuredClone(x));
  }
}
