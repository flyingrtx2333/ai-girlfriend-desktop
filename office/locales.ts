// 0.5.1's Chinese spreadsheet and presentation packs leave many controls null.
const commonToolbar = {
  save: '保存', exportPng: '导出图片', historyLabel: '历史记录', undo: '撤销', redo: '恢复',
  zoom: '缩放', zoomValue: '缩放：{value}', fontFamily: '字体', fontSize: '字号',
  decreaseFontSize: '减小字号', increaseFontSize: '增大字号', bold: '加粗', italic: '倾斜',
  textColor: '文字颜色', fillColor: '填充颜色', more: '更多', textFormattingLabel: '文字格式',
};
const commonReasons = {
  editorUnavailable: '编辑器尚未就绪。', noDocument: '请先打开文件。', readOnly: '文件为只读。',
  nothingToUndo: '没有可撤销的操作。', nothingToRedo: '没有可恢复的操作。',
  hostDisabled: '此处无法使用此操作。', unsupportedCommand: '暂不支持此操作。',
  invalidArguments: '请检查输入的值。', inputFailed: '先前的输入未能保存。',
  documentReplaced: '当前文件已切换。', targetChanged: '所选内容已变化。',
  commandFailed: '修改未能应用。', permissionDenied: '尚未允许此扩展执行该操作。',
  pluginUnavailable: '此扩展已停用。', aborted: '操作已取消。',
};
const commonEditor = {
  openError: '无法打开文件', openErrorDescription: '文件可能已损坏，或包含暂不支持的内容。',
  stoppedError: '编辑器遇到问题', loadError: '编辑器未能载入',
  loadErrorDescription: '请重新载入文件。', reloadPage: '重新载入', showDetails: '查看详情',
};
export function sheetLocale(base: any) {
  return {
    ...base,
    toolbar: {
      ...base.toolbar, ...commonToolbar, actionsLabel: '表格工具栏', fileActionsLabel: '文件',
      formulaBarLabel: '公式栏', nameBoxPlaceholder: '名称框', formulaPlaceholder: '输入数值或公式',
      print: '打印', paintFormat: '格式刷', currency: '货币格式', percent: '百分比格式',
      decreaseDecimal: '减少小数位', increaseDecimal: '增加小数位', moreNumberFormats: '更多数字格式',
      strikethrough: '删除线', borders: '边框', borderColor: '边框颜色', mergeCells: '合并单元格',
      horizontalAlignment: '水平对齐', verticalAlignment: '垂直对齐', textWrapping: '文字换行',
      groups: { ...base.toolbar.groups, history: '历史记录', file: '文件', print: '打印', paintFormat: '格式刷', zoom: '缩放', number: '数字格式', font: '字体', text: '文字格式', colors: '颜色', borders: '边框', merge: '合并单元格', alignment: '对齐' },
      numberFormats: { automatic: '自动', plainText: '纯文本', number: '数值', percent: '百分比', scientific: '科学计数', currency: '货币', date: '日期', time: '时间', custom: '自定义数字格式…' },
      merge: { all: '合并全部', horizontal: '横向合并', vertical: '纵向合并', unmerge: '取消合并' },
      horizontalAlign: { left: '左对齐', center: '居中', right: '右对齐' },
      verticalAlign: { top: '顶端', middle: '居中', bottom: '底端' },
      wrapping: { overflow: '溢出', wrap: '换行', clip: '裁剪' },
    },
    commands: { ...base.commands, fontSizeStep: '调整字号', numberFormat: '数字格式', decimalPlaces: '调整小数位', borderStyle: '边框样式', moreTools: '更多工具', customFontSize: '自定义字号…', fontSizePoints: '字号（磅）', customZoom: '自定义缩放…', zoomPercent: '缩放百分比', apply: '应用', cancel: '取消', reasons: { ...base.commands.reasons, ...commonReasons, documentLoading: '正在打开表格。', cellSelectionRequired: '请先选择单元格。', multipleCellsRequired: '请选择多个单元格。', multipleColumnsRequired: '请选择多列。', multipleRowsRequired: '请选择多行。', noMergedCells: '所选范围没有合并单元格。' } },
    editor: { ...base.editor, ...commonEditor, appLabel: '表格编辑器', stoppedErrorDescription: '请重新打开表格继续编辑。', openPrompt: '打开 XLSX 文件', sheetTabsLabel: '工作表' },
    proposals: { ...base.proposals, panelLabel: '待审阅修改', empty: '没有待审阅修改', accept: '接受', reject: '拒绝', forceApply: '应用最新修改' },
    a11y: { ...base.a11y, gridLabel: '表格', rowHeaderLabel: '第{row}行', columnHeaderLabel: '第{column}列', cellLabelSelected: '{address}，{value}，已选择', emptyCellLabel: '{address}，空白', emptyCellLabelSelected: '{address}，空白，已选择' },
  };
}
export function slidesLocale(base: any) {
  return {
    ...base,
    toolbar: {
      ...base.toolbar, ...commonToolbar, label: '幻灯片工具栏', present: '放映', slidesLabel: '幻灯片',
      addSlide: '添加幻灯片', deleteSlide: '删除幻灯片', newSlide: '新建幻灯片', newSlideWithLayout: '选择幻灯片版式', layoutOption: '版式{number}',
      addTextBox: '添加文本框', insertImage: '插入图片', fit: '适应窗口', selectToolShortcut: '选择（Esc）',
      textBoxTool: '文本框', shapeTool: '形状', mixed: '混合', underline: '下划线',
      undoShortcut: '撤销（⌘Z）', redoShortcut: '恢复（⇧⌘Z）', boldShortcut: '加粗（⌘B）', italicShortcut: '倾斜（⌘I）', underlineShortcut: '下划线（⌘U）',
      groups: { ...base.toolbar.groups, file: '文件', slides: '幻灯片', history: '历史记录', zoom: '缩放', tools: '工具', font: '字体', text: '文字格式', shape: '形状格式', alignment: '对齐' },
      align: { left: '左对齐', center: '居中', right: '右对齐', justify: '两端对齐' },
      noFill: '无填充', borderColor: '边框颜色', borderWidth: '边框宽度', noBorder: '无边框',
      cornerRadius: '圆角', shapeAdjustment: '调整形状', arrange: '排列', bringToFront: '置于顶层', bringForward: '上移一层', sendBackward: '下移一层', sendToBack: '置于底层',
    },
    slides: { ...base.slides, panelLabel: '幻灯片', fallbackTitle: '幻灯片{number}', canvasLabel: '第{current}张，共{total}张', canvasLabelWithSelection: '第{current}张，共{total}张；已选择{name}' },
    editor: { ...base.editor, ...commonEditor, appLabel: '幻灯片编辑器', opening: '正在打开幻灯片…', noSlides: '没有幻灯片', openPrompt: '打开 PPTX 文件', textInput: '幻灯片文字', selectionAnnouncement: '已选择文字', stoppedErrorDescription: '请先保留编辑内容，再重新打开幻灯片。' },
    commands: { ...base.commands, moreControls: '更多操作', selectTool: '选择', fontSizeStep: '调整字号', customFontSize: '自定义字号…', fontSizePoints: '字号（磅）', customColor: '自定义颜色…', hexColor: '十六进制颜色', apply: '应用', cancel: '取消', reasons: { ...base.commands.reasons, ...commonReasons, documentLoading: '正在打开幻灯片。', textSelectionRequired: '请先选择文字或文本框。', shapeRequired: '请先选择形状。', objectRequired: '请先选择形状或图片。', slideRequired: '请先添加幻灯片。' } },
  };
}
