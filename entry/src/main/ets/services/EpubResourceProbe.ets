import { fileIo as fs } from '@kit.CoreFileKit';
import { EpubInputError } from './EpubInputPolicy';
import { closeFile, openFile, readFile, statFile } from '../utils/FileIoBoundary';

export interface EpubResourceProbe { size: number; mediaType?: string; }
// Inspect bounded magic bytes as well as declared MIME/extension. A bitmap or
// font named .css/.bin must not bypass its actual decoder's resource limits.
export async function probePublicationResource(path: string): Promise<EpubResourceProbe> {
  const file = await openFile(path, fs.OpenMode.READ_ONLY);
  try {
    const size = (await statFile(file.fd)).size;
    const prefix = new Uint8Array(Math.min(size, 32));
    let offset = 0;
    while (offset < prefix.length) {
      const buffer = new ArrayBuffer(prefix.length - offset);
      const count = await readFile(file.fd, buffer);
      if (count <= 0) throw new EpubInputError('malformed');
      prefix.set(new Uint8Array(buffer, 0, count), offset); offset += count;
    }
    const result: EpubResourceProbe = { size: size };
    if (prefix.length < 2) return result;
    if ((prefix[0] === 255 && prefix[1] === 216) || (prefix[0] === 66 && prefix[1] === 77)) result.mediaType = 'image/raster';
    if (prefix.length < 12) return result;
    const view = new DataView(prefix.buffer);
    const magic = view.getUint32(0, false);
    if ((magic === 0x89504e47 && view.getUint32(4, false) === 0x0d0a1a0a) ||
      (magic === 0x47494638 && (prefix[4] === 55 || prefix[4] === 57) && prefix[5] === 97) ||
      (magic === 0x52494646 && view.getUint32(8, false) === 0x57454250) || view.getUint32(4, false) === 0x66747970) result.mediaType = 'image/raster';
    if ([0x00010000, 0x4f54544f, 0x74727565, 0x74746366, 0x774f4646, 0x774f4632].includes(magic)) result.mediaType = 'font/sfnt';
    return result;
  } finally { closeFile(file); }
}
