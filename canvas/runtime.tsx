import * as React from 'react';
import * as JSXRuntime from 'react/jsx-runtime';
import { createRoot, type Root } from 'react-dom/client';
import * as Charts from 'recharts';
import { transform } from 'sucrase';
import './style.css';

let root: Root | undefined;
let isolationError = '';
try {
  for (const name of ['mediaDevices', 'geolocation', 'clipboard', 'credentials', 'serviceWorker', 'bluetooth', 'usb', 'serial', 'hid', 'presentation', 'wakeLock']) {
    Object.defineProperty(navigator, name, { value: undefined, configurable: false, writable: false });
    Object.defineProperty(Object.getPrototypeOf(navigator), name, { value: undefined, configurable: false, writable: false });
  }
  for (const name of ['open', 'showOpenFilePicker', 'showSaveFilePicker', 'showDirectoryPicker', 'Notification']) {
    Object.defineProperty(window, name, { value: undefined, configurable: false, writable: false });
  }
} catch (error) { isolationError = String(error); }

class CanvasBoundary extends React.Component<React.PropsWithChildren, { error: string }> {
  state = { error: '' };
  static getDerivedStateFromError(error: unknown) { return { error: String(error) }; }
  render() {
    return this.state.error
      ? <pre role="alert" data-canvas-error>{this.state.error}</pre>
      : this.props.children;
  }
}

export async function render(source: string) {
  if (isolationError) throw new Error('当前系统未能隔离画布能力：' + isolationError);
  root?.unmount();
  const element = document.getElementById('canvas-root');
  if (!element) throw new Error('画布容器不可用');
  const modules: Record<string, unknown> = { react: React, 'react/jsx-runtime': JSXRuntime, recharts: Charts };
  const require = (name: string) => {
    if (!Object.hasOwn(modules, name)) throw new Error(`画布未内置此模块：${name}。可使用 react 和 recharts。`);
    return modules[name];
  };
  try {
    const compiled = transform(source, {
      transforms: ['typescript', 'jsx', 'imports'], filePath: 'document.canvas.tsx',
      jsxRuntime: 'automatic', production: true, disableESTransforms: true,
    }).code;
    const module = { exports: {} as { default?: React.ComponentType } };
    new Function('require', 'module', 'exports', compiled)(require, module, module.exports);
    const Component = module.exports.default;
    if (typeof Component !== 'function' && typeof Component !== 'object') throw new Error('请用 export default 导出 React 组件');
    root = createRoot(element);
    root.render(<CanvasBoundary><Component /></CanvasBoundary>);
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    const error = document.querySelector('[data-canvas-error]')?.textContent;
    if (error) throw new Error(error);
    return { rendered: true };
  } catch (error) {
    element.replaceChildren();
    const message = document.createElement('pre');
    message.setAttribute('role', 'alert'); message.dataset.canvasError = '';
    message.textContent = String(error); element.append(message);
    throw error;
  }
}
