'use strict';
const countryCodes=new Set(["AD", "AE", "AF", "AG", "AI", "AL", "AM", "AO", "AQ", "AR", "AS", "AT", "AU", "AW", "AX", "AZ", "BA", "BB", "BD", "BE", "BF", "BG", "BH", "BI", "BJ", "BL", "BM", "BN", "BO", "BQ", "BR", "BS", "BT", "BV", "BW", "BY", "BZ", "CA", "CC", "CD", "CF", "CG", "CH", "CI", "CK", "CL", "CM", "CN", "CO", "CP", "CR", "CU", "CV", "CW", "CX", "CY", "CZ", "DE", "DG", "DJ", "DK", "DM", "DO", "DZ", "EC", "EE", "EG", "EH", "ER", "ES", "ET", "EU", "FI", "FJ", "FK", "FM", "FO", "FR", "GA", "GB", "GD", "GE", "GF", "GG", "GH", "GI", "GL", "GM", "GN", "GP", "GQ", "GR", "GS", "GT", "GU", "GW", "GY", "HK", "HM", "HN", "HR", "HT", "HU", "IC", "ID", "IE", "IL", "IM", "IN", "IO", "IQ", "IR", "IS", "IT", "JE", "JM", "JO", "JP", "KE", "KG", "KH", "KI", "KM", "KN", "KP", "KR", "KW", "KY", "KZ", "LA", "LB", "LC", "LI", "LK", "LR", "LS", "LT", "LU", "LV", "LY", "MA", "MC", "MD", "ME", "MF", "MG", "MH", "MK", "ML", "MM", "MN", "MO", "MP", "MQ", "MR", "MS", "MT", "MU", "MV", "MW", "MX", "MY", "MZ", "NA", "NC", "NE", "NF", "NG", "NI", "NL", "NO", "NP", "NR", "NU", "NZ", "OM", "PA", "PC", "PE", "PF", "PG", "PH", "PK", "PL", "PM", "PN", "PR", "PS", "PT", "PW", "PY", "QA", "RE", "RO", "RS", "RU", "RW", "SA", "SB", "SC", "SD", "SE", "SG", "SH", "SI", "SJ", "SK", "SL", "SM", "SN", "SO", "SR", "SS", "ST", "SV", "SX", "SY", "SZ", "TC", "TD", "TF", "TG", "TH", "TJ", "TK", "TL", "TM", "TN", "TO", "TR", "TT", "TV", "TW", "TZ", "UA", "UG", "UM", "UN", "US", "UY", "UZ", "VA", "VC", "VE", "VG", "VI", "VN", "VU", "WF", "WS", "XK", "XX", "YE", "YT", "ZA", "ZM", "ZW"]);

const countryNames=typeof Intl.DisplayNames==='function'?new Intl.DisplayNames(['ru'],{type:'region'}):null;
function countryLabel(name){
 let code='',title=String(name||'');
 const emoji=title.match(/[\u{1F1E6}-\u{1F1FF}]{2}/u);
 if(emoji){code=Array.from(emoji[0],c=>String.fromCharCode(c.codePointAt(0)-0x1F1E6+65)).join('');}
 const prefix=!emoji&&title.match(/^(?:\[([a-z]{2})\]|\(([a-z]{2})\)|([a-z]{2})(?=$|[^a-z]))[\s|:·\-–—]*/i);
 if(prefix)code=(prefix[1]||prefix[2]||prefix[3]).toUpperCase();
 if(code==='UK')code='GB';
 if(!countryCodes.has(code))return {code:'',country:'',title};
 title=title.replace(emoji?emoji[0]:prefix[0],'').trim();
 const country=countryNames?.of(code)||code;
 return {code,country,title:title||country};
}
function renderCountryTitle(target,name){
 if(target.dataset.serverName===name)return;
 target.dataset.serverName=name;
 const info=countryLabel(name);target.replaceChildren();
 if(info.code){const flag=document.createElement('img');flag.className='country-flag';flag.src='/flags/'+info.code.toLowerCase()+'.svg';flag.width=24;flag.height=18;flag.alt=info.country;flag.title=info.country+' ('+info.code+')';target.append(flag);}
 const text=document.createElement('span');text.className='country-title';text.textContent=info.title;target.append(text);
}
