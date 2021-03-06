import { Controller } from 'stimulus';
import mermaid from 'mermaid';

export default class extends Controller {
  render(event) {
      if(mermaid) {
        $(this).delay(1000).queue(function()
          {
            mermaid.init({noteMargin: 10}, ".aicrowd-mermaid")
          });
      }
  }
}
