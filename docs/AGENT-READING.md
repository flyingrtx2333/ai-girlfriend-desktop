# 图表与选文

任务记录的 Markdown 产物和 Wiki 使用原生阅读器。预览中的 Mermaid 图表由随应用打包的渲染器绘制，双击可在独立窗口缩放；原文保留完整代码。

## 文档打开流程

```mermaid
flowchart LR
    R[AgentRecordWindow] --> P[AgentMarkdownReader]
    P --> D[AgentMarkdownDocument]
    D --> T[原生文字、表格与本地图片]
    D --> M[Mermaid 代码块]
    M --> W[离线 WebKit 渲染]
    W --> V[PDF 矢量图]
    V --> P
    P --> S[只读来源窗口]
    S --> F[AgentFiles 工作区边界]
```

## 选文加入草稿

选中文字后点击“加入任务”，内容以文件路径和引用形式追加到该文档所属任务的草稿。切换到其他任务后再加入，仍回到原任务；其他任务的草稿会保存。此操作不会发送消息，也不会修改文档。

```mermaid
sequenceDiagram
    actor U as 用户
    participant R as 文档阅读器
    participant C as ControlWindow
    participant S as AgentStore
    U->>R: 选择文字并加入任务
    R->>C: 选文快照、文件和工作区
    C->>C: 核对原任务与工作区
    C->>S: 保存当前草稿
    C->>S: 追加选文并保存原任务草稿
    C-->>U: 聚焦原任务输入框
```

## 阅读边界

```mermaid
mindmap
  root((文档阅读))
    原生内容
      章节与锚点
      UTF8 原文
      本地图片与表格
    Mermaid
      离线资源
      严格模式
      矢量缩放
    选文
      保留原草稿
      不自动发送
      工作区校验
```

图片与文档链接沿用工作区文件工具的边界。图表不访问网络或本地文件，也不能调用应用工具。每页最多预览16张图表，单张源码最多32KB、500条边；超限或语法错误可切换原文检查。选文最多16KB，合并后的任务草稿最多100KB。
