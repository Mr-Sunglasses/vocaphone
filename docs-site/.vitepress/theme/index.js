import DefaultTheme from 'vitepress/theme';
import { installDiagramViewer } from '../diagram-viewer.mjs';
import '../custom.css';

export default {
  ...DefaultTheme,
  enhanceApp(ctx) {
    DefaultTheme.enhanceApp?.(ctx);
    installDiagramViewer(ctx.router);
  },
};
