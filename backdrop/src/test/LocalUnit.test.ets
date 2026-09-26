// 占位用例：HAR 主体是 C++/GLES（无 ArkTS 逻辑可测），这里只保证模块的测试链路可用。
import { describe, it, expect } from '@ohos/hypium';

export default function localUnitTest() {
  describe('backdropModule', () => {
    it('test_entry_is_executable', 0, () => {
      expect(true).assertTrue();
    });
  });
}
