import path from 'node:path';
import { signNativeCheck } from './native-signing.mjs';

if (process.argv.length !== 3) throw new Error('请指定独立验收应用的路径。');
signNativeCheck(path.resolve(process.argv[2]));
