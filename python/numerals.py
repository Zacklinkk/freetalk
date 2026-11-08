"""Conservative numeric typography: only convert when the context denotes a number."""
import re
from disfluency import LITERALS

DIGITS = dict(zip('零〇一二三四五六七八九', '00123456789'))
DIGITS.update({'两':'2','幺':'1'})
SMALL = {'十':10,'百':100,'千':1000}
BIG = {'万':10000,'亿':100000000}
CHARS = '零〇一二两三四五六七八九十百千万亿幺'
TOKEN = re.compile(r'(?:百分之)?[负正]?[{}]+(?:点[零〇一二三四五六七八九]+)?(?:[多余来][万亿]?)?'.format(CHARS))
COUNTERS = r'个|条|道|次|份|项|组|页|行|列|张|本|台|人|名|位|岁|年|月|日|号|天|周|小时|分钟|秒|点|元|块|角|分|米|公里|斤|公斤|克|吨|升|毫升|字|段|种|版|倍|成|轮|步|章|节|款|辆|支|根|只|套|批|度|赫兹|千赫兹|GB|GiB|MB|毫秒|厘米|毫米|%|％'
# Numeric-looking parts of words/names/weekdays are not quantities.
WORDS = re.compile(r'星期[一二三四五六日天]|礼拜[一二三四五六日天]|周[一二三四五六日天]|一(?:下|直|起|样|般|些|切|旦|定|致|共|边|方面|会儿|点儿)|万一|千万(?:别|不要)|百姓|三思|四舍五入|五花八门|七嘴八舌|乱七八糟|独一无二|一心一意|一举两得|三心二意|九牛一毛|三十而立|十有八九|二话不说|三番五次|五颜六色|四面八方|一干二净')
LEXICAL = re.compile(r'统一|唯一|单一|同一|逐一|不一|一并|一律|一概|一贯|一部分|一系列|一体|一类|一线|一流|一番|一味|一度|一向|一时|一再|一起|十分(?=方便|重要|困难|简单|清楚|明确|容易|稳定|相似|必要|满意|感谢|高兴|复杂|好|大|小)|万分|百度|百科|万维|两者|二者|双方|三者|两全|三维|二维|一维')
NUMBER_CUE = re.compile(r'(?:编号|号码|编码|密码|数字|输入|读作|版本|金额|预算|总计|共计|数量|人数|样本数)(?:为|是|有|约|：|:|\s)*$')
EXACT_ONE_CUE = re.compile(r'(?:只有|仅有|仅|总共|一共|共|还剩|剩|恰好|正好|至少|最多|最少|不超过|只用|保留|[=＝:：])\s*$')
VERSION_HEAD = re.compile(r'(?<![A-Za-z0-9_])([A-Za-z][A-Za-z0-9_.+-]{1,39}|[vV])[ \t]*$')
VERSION_TAIL = re.compile(r'^(?:$|[\s，,。！？!?；;：:、/()（）]|的|和|与|或|有|没有|是|在|比|以及|到|对比|版本|模型|资源|可|能|支持|用于|用来|来|重新|再|先|跑|测|做|生成|处理|表现|速度|性能|价格)')

def integer(token):
    if not token: return None
    if all(c in DIGITS for c in token):
        # A digit sequence is a code/year; retain leading zeros.
        return ''.join(DIGITS[c] for c in token)
    if re.search(r'[一二两三四五六七八九]{2}', token): return None # 两三 / 五六十 are estimates
    # Colloquial 一千二 / 一百二 has ambiguous omitted units.
    if re.search(r'[百千万亿][一二两三四五六七八九]$',token): return None
    total, section, digit, last_small = 0, 0, 0, 10000
    for c in token:
        if c in DIGITS: digit = int(DIGITS[c])
        elif c in SMALL:
            unit=SMALL[c]
            if unit >= last_small: return None
            section += (digit or 1)*unit; digit=0; last_small=unit
        elif c in BIG:
            section += digit
            if not section and not total: return None
            if c == '亿': total=(total+section)*BIG[c]
            else: total += section*BIG[c]
            section=0;digit=0;last_small=10000
        else: return None
    return str(total+section+digit)

def numeric(token):
    percent=token.startswith('百分之')
    if percent: token=token[3:]
    sign=''
    if token.startswith(('负','正')):
        sign='-' if token[0]=='负' else '+';token=token[1:]
    suffix=''
    approximate=re.search(r'[多余来][万亿]?$',token)
    if approximate: suffix=approximate[0]; token=token[:approximate.start()]
    # Retain readable magnitude units: 一百万 -> 100万; not a semantic rounding.
    magnitude=''
    if token.endswith(('万','亿')) and not any(c in token[:-1] for c in BIG):
        magnitude=token[-1];token=token[:-1]
    parts=token.split('点')
    left=integer(parts[0])
    if left is None: return None
    if len(parts)==2:
        if not parts[1] or not all(c in DIGITS for c in parts[1]):return None
        left += '.'+''.join(DIGITS[c] for c in parts[1])
    return sign+left+magnitude+suffix+('%' if percent else '')

def normalize(text, protected_terms=()):
    # Explicit identifiers have a different grammar from ordinary Chinese prose.
    # Only a version prefix or a model/code label opens this conversion scope.
    extra = 0
    literal_ranges = [(m.start(),m.end()) for m in LITERALS.finditer(text)]
    def identifier(match):
        nonlocal extra
        if any(match.start()<b and match.end()>a for a,b in literal_ranges): return match[0]
        if any(term and term in match[0] for term in protected_terms): return match[0]
        value = match['value']
        value = re.sub(r'(?:横杠|连字符|杠)[。\s]*', '-', value)
        value = ''.join(DIGITS.get(c,c) for c in value).replace('点','.')
        if value != match['value']: extra += 1
        return match['head'] + value
    # Do not parse dates, prose or quoted strings as product codes.
    pattern = r'(?P<head>(?:型号|编号|编码)(?:是|为|：|:|\s)*)(?P<value>[A-Z]{1,12}(?:(?:横杠|连字符|杠)[。\s]*|[A-Z0-9零〇一二三四五六七八九幺-]){1,60})'
    text = re.sub(pattern, identifier, text)
    literal_ranges = [(m.start(),m.end()) for m in LITERALS.finditer(text)]
    pattern = r'(?P<head>(?<![A-Za-z0-9_])[vV])(?P<value>[0-9零〇一二三四五六七八九]+(?:点[0-9零〇一二三四五六七八九]+)+)(?![A-Za-z])'
    text = re.sub(pattern, identifier, text)
    protected=[(m.start(),m.end()) for pattern in (LITERALS,WORDS,LEXICAL) for m in pattern.finditer(text)]
    for term in protected_terms:
        if isinstance(term,str) and term:
            protected += [(m.start(),m.end()) for m in re.finditer(re.escape(term),text)]
    # Spoken enumeration, approximate amounts and fractions retain their natural spelling.
    contextual = r'第[一二三四五六七八九十]+(?=[，、。：:；;.!?！？]|$)|[{}]+分之[{}]+|(?:一两|两三|三四|四五|五六|六七|七八|八九|几)[个条次份项组页行天周月年十百千万亿]'.format(CHARS,CHARS)
    protected += [(m.start(),m.end()) for m in re.finditer(contextual,text) if not m[0].startswith('百分之')]
    # Degree phrases are not a count or time: 长一点 / 再快一点 / 有一点。
    degree = r'(?:长|短|大|小|多|少|快|慢|好|早|晚|轻|重|有|加|留|给|差|再)一点(?![零〇一二三四五六七八九\d半钟])'
    protected += [(m.start(),m.end()) for m in re.finditer(degree,text)]
    patches=[]
    for m in TOKEN.finditer(text):
        a,b=m.span();word=m[0]
        if any(a<r and b>l for l,r in protected):continue
        before,after=text[:a],text[b:]
        if before.endswith(('星期','礼拜','周')):continue
        bare=word.removeprefix('百分之').lstrip('负正')
        is_digits=all(c in DIGITS for c in bare)
        standalone = not before.strip(' ：:，,。') and not after.strip(' ，,。.!！?？')
        cue = bool(NUMBER_CUE.search(before))
        quantity = bool(re.match(COUNTERS,after)) and not any(l <= b < r for l,r in protected)
        # Model/product identifiers use numeric versions, regardless of brand.
        # Lexical phrases (一直/一般/五花八门), quotations and personal names
        # are protected above; a following classifier still uses quantity rules.
        name = VERSION_HEAD.search(before)
        version = bool(name and not quantity and VERSION_TAIL.match(after) and (name[1] == 'v' or any(c.isupper() for c in name[1])))
        ordinal = before.endswith('第') and quantity
        if not (quantity or ordinal or standalone or cue or version or word.startswith('百分之')):
            continue
        if is_digits and len(bare)==2 and re.fullmatch(r'[一二两三四五六七八九]{2}',bare):
            if not cue:continue
        # “一个想法 / 一种方式” is often an indefinite article, not a count.
        if bare=='一' and not (ordinal or cue or version or standalone or EXACT_ONE_CUE.search(before)):
            date_or_clock = bool((before.endswith('月') and after.startswith(('日','号'))) or re.match(r'点(?:半|整|钟)',after) or (re.search(r'上午|下午|中午|晚上|凌晨|早上',before[-8:]) and after.startswith('点')))
            if not date_or_clock:continue
        # A multi-character numeral embedded in a name is usually not a quantity.
        if not is_digits and len(bare)>1 and not re.search(r'[十百千万亿点]',bare):continue
        new=numeric(word)
        if new is not None and new!=word:patches.append((a,b,new))
    for a,b,new in reversed(patches):text=text[:a]+new+text[b:]
    return text,len(patches)+extra
