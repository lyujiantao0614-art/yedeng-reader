import { BookshelfDefaultMode, BookshelfTheme } from '../domain/LibraryPresentation';

export type BookshelfColorRole = 'canvas' | 'surface' | 'muted' | 'text' | 'secondary' |
  'divider' | 'accent' | 'onAccent' | 'accentContainer' | 'error' | 'errorContainer' |
  'success' | 'warning' | 'panel' | 'panelText' | 'panelSecondary' | 'panelMuted';

// Art themes have fixed palettes. Only the default resolves the product's
// system light/dark resources, independently of the Reader appearance setting.
export function bookshelfColor(theme: BookshelfTheme, role: BookshelfColorRole,
  defaultMode: BookshelfDefaultMode = 'system'): ResourceColor {
  if (theme === 'starry') {
    switch (role) {
      case 'canvas': return '#09172E';
      case 'surface': return '#172942';
      case 'muted': return '#263B55';
      case 'text': return '#F6F3E9';
      case 'secondary': return '#D1DCE3';
      case 'divider': return '#66788B';
      case 'accent': return '#E9C779';
      case 'onAccent': return '#19273A';
      case 'accentContainer': return '#40516B';
      case 'error': return '#F4B5B0';
      case 'errorContainer': return '#583A45';
      case 'success': return '#B6D8BB';
      case 'warning': return '#F1CE91';
      case 'panel': return '#1D324E';
      case 'panelText': return '#F6F3E9';
      case 'panelSecondary': return '#D1DCE3';
      case 'panelMuted': return '#324861';
    }
  }
  if (theme === 'fan-kuan') {
    switch (role) {
      case 'canvas': return '#B6AD96';
      case 'surface': return '#E7DEC7';
      case 'muted': return '#D8CFB9';
      case 'text': return '#26372D';
      case 'secondary': return '#4E6052';
      case 'divider': return '#A7AB98';
      case 'accent': return '#385F47';
      case 'onAccent': return '#F8F5E9';
      case 'accentContainer': return '#CBDAC7';
      case 'error': return '#8D3530';
      case 'errorContainer': return '#F1DFD6';
      case 'success': return '#32633E';
      case 'warning': return '#79501A';
      case 'panel': return '#E2D9C2';
      case 'panelText': return '#26372D';
      case 'panelSecondary': return '#4E6052';
      case 'panelMuted': return '#D1C8B2';
    }
  }
  if (theme === 'earthrise') {
    switch (role) {
      case 'canvas': return '#050B15';
      case 'surface': return '#BC142234';
      case 'muted': return '#DF213247';
      case 'text': return '#F0F7F8';
      case 'secondary': return '#C3D6DD';
      case 'divider': return '#5B7280';
      case 'accent': return '#9DD9E4';
      case 'onAccent': return '#11232E';
      case 'accentContainer': return '#315263';
      case 'error': return '#F4B5B0';
      case 'errorContainer': return '#593C49';
      case 'success': return '#B6D8BB';
      case 'warning': return '#F1CE91';
      case 'panel': return '#D51A2C3F';
      case 'panelText': return '#F0F7F8';
      case 'panelSecondary': return '#C3D6DD';
      case 'panelMuted': return '#2B4054';
    }
  }
  if (defaultMode === 'light') {
    switch (role) {
      case 'canvas': return '#E0E5E5';
      case 'surface': return '#F9F7F1';
      case 'muted': return '#E9ECE9';
      case 'text': return '#243139';
      case 'secondary': return '#526168';
      case 'divider': return '#BEC8CA';
      case 'accent': return '#805036';
      case 'onAccent': return '#FFF9EF';
      case 'accentContainer': return '#E7D8C8';
      case 'error': return '#9D3530';
      case 'errorContainer': return '#F9F7F1';
      case 'success': return '#32633E';
      case 'warning': return '#79501A';
      case 'panel': return '#EEF0E9';
      case 'panelText': return '#263238';
      case 'panelSecondary': return '#536169';
      case 'panelMuted': return '#DCE3DD';
    }
  }
  if (defaultMode === 'dark') {
    switch (role) {
      case 'canvas': return '#1C2933';
      case 'surface': return '#303C44';
      case 'muted': return '#374650';
      case 'text': return '#EAE9E3';
      case 'secondary': return '#BAC5C9';
      case 'divider': return '#566773';
      case 'accent': return '#E9BA85';
      case 'onAccent': return '#2B2925';
      case 'accentContainer': return '#5A4E42';
      case 'error': return '#F4B5B0';
      case 'errorContainer': return '#303C44';
      case 'success': return '#B6D8BB';
      case 'warning': return '#F1CE91';
      case 'panel': return '#30404A';
      case 'panelText': return '#EFEDE3';
      case 'panelSecondary': return '#C3CDD1';
      case 'panelMuted': return '#41535C';
    }
  }
  switch (role) {
    case 'canvas': return $r('app.color.product_canvas');
    case 'surface': return $r('app.color.product_surface');
    case 'muted': return $r('app.color.product_surface_muted');
    case 'text': return $r('app.color.product_text_primary');
    case 'secondary': return $r('app.color.product_text_secondary');
    case 'divider': return $r('app.color.product_divider');
    case 'accent': return $r('app.color.product_accent');
    case 'onAccent': return $r('app.color.product_on_accent');
    case 'accentContainer': return $r('app.color.product_accent_container');
    case 'error': return $r('app.color.product_error');
    case 'errorContainer': return $r('app.color.product_error_container');
    case 'success': return $r('app.color.product_success');
    case 'warning': return $r('app.color.product_warning');
    case 'panel': return $r('app.color.product_panel');
    case 'panelText': return $r('app.color.product_panel_text');
    case 'panelSecondary': return $r('app.color.product_panel_secondary');
    case 'panelMuted': return $r('app.color.product_panel_muted');
  }
}

export function bookshelfOuterText(theme: BookshelfTheme, secondary: boolean = false,
  defaultMode: BookshelfDefaultMode = 'system'): ResourceColor {
  if (theme === 'fan-kuan') return secondary ? '#EFE4CD' : '#FFF8E8';
  return bookshelfColor(theme, secondary ? 'secondary' : 'text', defaultMode);
}
