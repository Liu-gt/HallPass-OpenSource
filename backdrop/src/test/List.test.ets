// backdrop HAR 的本地单元测试入口（模板占位）。
// hvigor 的 test 任务会为**每个模块**生成脚手架并 import 本文件；HAR 里缺这个文件时
// 全量 `hvigorw test`（不带 -p module=entry）会在 backdrop 模块的脚手架处编译失败。
import localUnitTest from './LocalUnit.test';

export default function testsuite() {
  localUnitTest();
}
