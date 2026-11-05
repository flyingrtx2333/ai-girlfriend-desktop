# Q 版鲸鱼娘 · 轻量互动模型

本模型为 DeepSeek 非官方同人作品，按 CC BY-NC-SA 4.0 使用，仅限非商业用途。

- 原角色「溟月」：上善无形，https://www.pixiv.net/users/62155430
- 女仆版设计：ZipZipPipe，https://www.pixiv.net/users/18604994
- 参考适配：Small-tailqwq，https://github.com/Small-tailqwq/dsh-deep-whale
- 3D 重建：AI Moe Atlas，https://github.com/SelinLee/ai-moe-atlas

源模型：deep-whale-maid v0.5.0。上游完整署名和建模说明见 UPSTREAM-NOTICE.txt，许可原文见 LICENSE.txt。

本项目修改：2026-11-03，保持原生 Q 版几何比例，离线减面并保留顶点颜色；展示时移除底座，按头、身体、眼睛、头发和尾巴分组，合并同材质网格，加入部件级眨眼、口型和互动动画。没有全身骨骼或布料物理解算，不声称完全还原原作者隐藏视角。与模型有关的衍生内容同样按 CC BY-NC-SA 4.0 提供。

源文件和输出文件哈希、面数与体积见 source.json。原始模型保存在项目 reference-assets/whale-maid/，可用 npm run prepare:model 重建轻量文件。
