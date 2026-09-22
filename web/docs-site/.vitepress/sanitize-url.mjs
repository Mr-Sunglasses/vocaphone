const invalidProtocolRegex = /^([^\w]*)(javascript|data|vbscript)/im;
const htmlEntitiesRegex = /&#(\w+)(^\w|;)?/g;
const htmlCtrlEntityRegex = /&(newline|tab);/gi;
const ctrlCharactersRegex = /[\u0000-\u001F\u007F-\u009F\u2000-\u200D\uFEFF]/gim;
const urlSchemeRegex = /^.+(:|&colon;)/gim;
const whitespaceEscapeCharsRegex = /(\\|%5[cC])((%(6[eE]|72|74))|[nrt])/g;
const relativeFirstCharacters = ['.', '/'];

function isRelativeUrlWithoutProtocol(url) {
  return relativeFirstCharacters.includes(url[0]);
}

function decodeHtmlCharacters(value) {
  return value.replace(ctrlCharactersRegex, '').replace(htmlEntitiesRegex, (_, dec) =>
    String.fromCharCode(dec),
  );
}

function decodeURI(value) {
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}

export function sanitizeUrl(url) {
  if (!url) return 'about:blank';

  let decodedUrl = decodeURI(String(url).trim());
  let charsToDecode;
  do {
    decodedUrl = decodeHtmlCharacters(decodedUrl)
      .replace(htmlCtrlEntityRegex, '')
      .replace(ctrlCharactersRegex, '')
      .replace(whitespaceEscapeCharsRegex, '')
      .trim();
    decodedUrl = decodeURI(decodedUrl);
    charsToDecode = decodedUrl.match(ctrlCharactersRegex)
      || decodedUrl.match(htmlEntitiesRegex)
      || decodedUrl.match(htmlCtrlEntityRegex)
      || decodedUrl.match(whitespaceEscapeCharsRegex);
  } while (charsToDecode && charsToDecode.length > 0);

  if (!decodedUrl) return 'about:blank';
  if (isRelativeUrlWithoutProtocol(decodedUrl)) return decodedUrl;

  const trimmedUrl = decodedUrl.trimStart();
  const urlScheme = trimmedUrl.match(urlSchemeRegex)?.[0]?.toLowerCase().trim();
  if (!urlScheme) return decodedUrl;
  if (invalidProtocolRegex.test(urlScheme)) return 'about:blank';

  const backSanitized = trimmedUrl.replace(/\\/g, '/');
  if (urlScheme === 'mailto:' || urlScheme.includes('://')) return backSanitized;
  if (urlScheme === 'http:' || urlScheme === 'https:') {
    if (!URL.canParse(backSanitized)) return 'about:blank';
    const parsed = new URL(backSanitized);
    parsed.protocol = parsed.protocol.toLowerCase();
    parsed.hostname = parsed.hostname.toLowerCase();
    return parsed.toString();
  }
  return backSanitized;
}
