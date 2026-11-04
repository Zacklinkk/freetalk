import sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'python'))
from numerals import normalize
class NumeralTests(unittest.TestCase):
    def test_codes_and_quantities(self):
        cases={'零一二三':'0123','保留五百条':'保留500条','预算一百多万':'预算100多万','二零二六年十一月一日':'2026年11月1日','一百万':'100万','十二万三千元':'123000元','零点零五秒':'0.05秒','百分之十二点五':'12.5%','负三点五度':'-3.5度','两个样本':'2个样本','一千零二个':'1002个','编号一二':'编号12','第一版SFT用十二个样本':'第1版SFT用12个样本','只有一个样本':'只有1个样本'}
        for raw,expected in cases.items():
            with self.subTest(raw=raw):self.assertEqual(normalize(raw)[0],expected)
    def test_meaningful_words_and_ambiguity(self):
        for raw in ['张三说周一再看一下。','一般可以一起处理，一定不要改。','万一失败，千万不要删除。','一千二','一百二','两三天','五六十个','三心二意','一举两得','保留 `一百` 和 https://a.test/一百。','字符串“零一二三”要保持原样。']:
            with self.subTest(raw=raw):self.assertEqual(normalize(raw)[0],raw)
    def test_idempotent_and_existing_digits(self):
        text=normalize('保留五百条，编号零一二三，预算一百多万。')[0]
        self.assertEqual(normalize(text)[0],text)
        self.assertEqual(normalize('API v0.2.1，500条和100多万。')[0],'API v0.2.1，500条和100多万。')
    def test_degree_expression_is_not_a_number(self):
        self.assertEqual(normalize('长一点，再快一点，有一点困难。')[0],'长一点，再快一点，有一点困难。')
        self.assertEqual(normalize('下午一点半，耗时一点五秒。')[0],'下午1点半，耗时1.5秒。')
    def test_words_before_classifier_are_not_counts(self):
        text='统一字体，统一字号，统一行距。同一条规则，唯一一个问题。百度搜索，十分方便。'
        self.assertEqual(normalize(text)[0],text)
    def test_natural_prose_and_real_quantities(self):
        raw='我有一个想法，第一，统一字体；第二，保留五百条，用十二个样本。'
        expected='我有一个想法，第一，统一字体；第二，保留500条，用12个样本。'
        self.assertEqual(normalize(raw)[0],expected)
    def test_ambiguous_names_estimates_and_fractions(self):
        for raw in ['三六零公司','五十铃汽车','一两个月','几百条','三分之一','万万不可','千千万万','十分相似']:
            with self.subTest(raw=raw):self.assertEqual(normalize(raw)[0],raw)
        self.assertEqual(normalize('查询三六零公司的二十条记录。',['三六零公司'])[0],'查询三六零公司的20条记录。')
if __name__=='__main__':unittest.main()
