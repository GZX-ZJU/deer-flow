import assert from "node:assert/strict";

const { shouldAnimateTextNode, splitTextForAnimation } = await import(
  new URL("./split-words.ts", import.meta.url).href
);

assert.equal(shouldAnimateTextNode("这是一个正常的中文句子。"), true);
assert.equal(shouldAnimateTextNode("for Baidu screenshot test"), false);
assert.equal(shouldAnimateTextNode("Target URL:"), false);
assert.equal(shouldAnimateTextNode("Test screenshot functionality with Temu report URL"), false);
assert.equal(
  shouldAnimateTextNode("/mnt/skills/custom/playwright-skill/baidu-test.js"),
  false,
);
assert.equal(shouldAnimateTextNode("https://www.baidu.com"), false);
assert.equal(shouldAnimateTextNode("前端压缩 test"), false);
assert.deepEqual(splitTextForAnimation("前端压缩过程中"), [
  "前端",
  "压缩",
  "过程",
  "中",
]);
assert.deepEqual(splitTextForAnimation("baidu-test.js"), ["baidu-test.js"]);

console.log("split-words.test.mts passed");
