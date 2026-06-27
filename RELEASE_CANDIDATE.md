# Release Candidate Summary

版本状态：Release Candidate / 本机试运行版
生成时间：2026-06-27 16:50:24 +08:00

## Gate 状态

- 数据层：PASS
- AllSupportedRegionsSmoke：PASS，47 地区
- Target200Coverage：PARTIAL
- English no-CJK：PASS
- UiRegionRenderSmoke：PASS，24/24
- RealUiInteractionSmoke：FAIL，作为自动化测试限制记录，不阻塞人工试运行

## 最终证据

- AllSupportedRegionsSmoke：reports/region-smoke-200/20260626-124918/summary.json
- English no-CJK：reports/ui-final-gate/english-no-cjk-20260627-123905/english-mode-no-cjk.json
- English 截图：reports/ui-final-gate/english-no-cjk-20260627-123905/normal-english-long-location.png
- UiRegionRenderSmoke：reports/ui-region-render-smoke/20260627-124851/ui-region-render-smoke.json
- RealUiInteractionSmoke：reports/ui-final-gate/20260627-010417/real-ui-interaction-smoke.json
- 最终证据索引：reports/final-evidence/english-ui-gate-20260627-125712/final-evidence-index.json

## 冻结范围

本 Release Candidate 冻结天气业务、UI 布局、地区数据、缓存逻辑、抽屉逻辑和英文翻译。后续只允许人工试运行反馈驱动的明确修复。
