export type TxtEncodingChoice = 'auto' | 'utf-8' | 'utf-16le' | 'utf-16be' |
  'gb18030' | 'gbk' | 'big5' | 'shift_jis' | 'euc-jp' | 'iso-2022-jp' |
  'euc-kr' | 'windows-1252' | 'windows-1251' | 'windows-1250';

export interface TxtPreview {
  valid: boolean;
  excerpt: string;
  encoding: string;
  message: string;
}
