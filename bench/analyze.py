#!/usr/bin/env python3
"""Strict JSONL analysis, stdlib only. Incomplete views remain visible as censored."""
import argparse,collections,csv,json,math,pathlib,sys

def percentile(values, q):
    if not values: return None
    s=sorted(values); pos=(len(s)-1)*q; low=math.floor(pos); high=math.ceil(pos)
    return s[low]+(s[high]-s[low])*(pos-low)

def analyze(paths, allow_incomplete=False):
    groups={}; seen=set()
    for path in paths:
        lines=path.read_text().splitlines()
        if not lines: raise ValueError(f'{path}: empty file')
        records=[json.loads(line) for line in lines]
        header=records[0]
        if header.get('type')!='runHeader': raise ValueError(f'{path}: missing run header')
        if header['run_id'] in seen: raise ValueError(f'duplicate run id: {header["run_id"]}')
        seen.add(header['run_id'])
        events=records[1:]
        if not allow_incomplete and sum(e.get('event')=='runEnd' for e in events)!=1: raise ValueError(f'{path}: missing or duplicate runEnd; use --allow-incomplete only for diagnosis')
        key=tuple(header[k] for k in ('strategy','format','network','script'))+(header.get('configuration_sha256','unknown'),)
        g=groups.setdefault(key,dict(ttff=[],first=[],swipe=[],views=0,frames=0,stalls=0,stall_s=0,network=0,cache=0,waste=0,errors=0,runs=0,incomplete=0,max_players=0,peak_memory=0,ready_arrivals=0,arrivals=0,decisions=0,plan_changes=0,budget_sum=0))
        g['runs']+=1
        starts={}; frames=set(); summaries=set()
        for e in events:
            kind=e.get('event'); m=e.get('metrics',{}); props=e.get('properties',{}); activation=props.get('activation_id')
            if kind=='viewStart':
                if not activation or activation in starts: raise ValueError(f'{path}: invalid viewStart activation')
                starts[activation]=e
                if m.get('next_arrival', len(starts)>1):
                    g['arrivals']+=1
                    g['ready_arrivals']+=props.get('readiness_tier') in ('warmPlayer','cachedBytes')
            elif kind=='firstFrame':
                if activation not in starts or activation in frames: raise ValueError(f'{path}: unmatched/duplicate firstFrame')
                if starts[activation]['item_id']!=e['item_id']: raise ValueError(f'{path}: wrong item for firstFrame')
                ttff=m['ttff_ms']
                if not math.isfinite(ttff) or ttff<0: raise ValueError(f'{path}: invalid TTFF')
                measured=(e['monotonic_s']-starts[activation]['metrics']['request_monotonic_s'])*1000
                if abs(ttff-measured)>10: raise ValueError(f'{path}: inconsistent monotonic TTFF')
                frames.add(activation); g['ttff'].append(ttff)
                g['swipe' if props.get('activation_reason')=='swipe' else 'first'].append(ttff)
            elif kind=='startupSummary':
                if activation not in starts or activation in summaries: raise ValueError(f'{path}: invalid startupSummary')
                summaries.add(activation); g['stalls']+=m.get('stall_count_10s',0); g['stall_s']+=m.get('stall_time_10s',0)
            elif kind=='prefetchDecision':
                g['decisions']+=1; g['plan_changes']+=m.get('plan_changed',0); g['budget_sum']+=m.get('budget_bytes',0)
            elif kind=='transfer': g['network']+=m.get('network_bytes',0); g['cache']+=m.get('cache_bytes',0)
            elif kind=='runEnd': g['waste']+=m.get('wasted_prefetch_bytes',0)
            elif kind in ('error','transportError','prefetchError'): g['errors']+=1
            g['max_players']=max(g['max_players'],m.get('live_player_count',0)); g['peak_memory']=max(g['peak_memory'],m.get('memory_bytes',0))
        if not allow_incomplete and set(starts)!=summaries: raise ValueError(f'{path}: startup summaries incomplete')
        g['views']+=len(starts); g['frames']+=len(frames); g['incomplete']+=len(starts)-len(frames)
    rows=[]
    for k,g in sorted(groups.items()):
        rows.append(dict(strategy=k[0],format=k[1],network=k[2],script=k[3],configuration=k[4][:12],runs=g['runs'],views=g['views'],frames=g['frames'],censored=g['incomplete'],p50_ms=percentile(g['ttff'],.5),p90_ms=percentile(g['ttff'],.9),p99_ms=percentile(g['ttff'],.99),first_p50_ms=percentile(g['first'],.5),swipe_p50_ms=percentile(g['swipe'],.5),pct_le_100_ms=100*sum(t<=100 for t in g['ttff'])/g['views'] if g['views'] else 0,stall_count_10s=int(g['stalls']),stall_seconds_10s=g['stall_s'],network_bytes=int(g['network']),cache_bytes=int(g['cache']),wasted_prefetch_bytes=int(g['waste']),errors=g['errors'],ready_hit_rate=g['ready_arrivals']/g['arrivals'] if g['arrivals'] else None,plan_changes=int(g['plan_changes']),average_budget_bytes=g['budget_sum']/g['decisions'] if g['decisions'] else None,policy_decisions=g['decisions'],max_players=int(g['max_players']),peak_memory_bytes=int(g['peak_memory'])))
    return rows

def main():
    p=argparse.ArgumentParser(); p.add_argument('inputs',nargs='+'); p.add_argument('--output',default='bench/results/summary'); p.add_argument('--allow-incomplete',action='store_true'); a=p.parse_args()
    paths=[]
    for raw in a.inputs:
        f=pathlib.Path(raw)
        paths.extend(sorted(f.glob('*.jsonl')) if f.is_dir() else [f])
    try: rows=analyze(paths,a.allow_incomplete)
    except (ValueError,KeyError,json.JSONDecodeError) as e: raise SystemExit(str(e))
    if not rows: raise SystemExit('No runs')
    out=pathlib.Path(a.output); out.parent.mkdir(parents=True,exist_ok=True)
    with out.with_suffix('.csv').open('w',newline='') as f:
        writer=csv.DictWriter(f,fieldnames=list(rows[0])); writer.writeheader(); writer.writerows(rows)
    columns=['strategy','format','network','script','views','censored','p50_ms','p90_ms','p99_ms','pct_le_100_ms','stall_count_10s','network_bytes','cache_bytes','wasted_prefetch_bytes','errors','ready_hit_rate','plan_changes','average_budget_bytes']
    def value(v): return '—' if v is None else f'{v:.1f}' if isinstance(v,float) else str(v)
    md='| '+' | '.join(columns)+' |\n| '+' | '.join('---' for _ in columns)+' |\n'
    md+='\n'.join('| '+' | '.join(value(r[c]) for c in columns)+' |' for r in rows)+'\n'
    if any(json.loads(f.read_text().splitlines()[0]).get('simulator') for f in paths): md='**simulator smoke run — not benchmark numbers**\n\n'+md
    out.with_suffix('.md').write_text(md); print(md)
if __name__=='__main__': main()
