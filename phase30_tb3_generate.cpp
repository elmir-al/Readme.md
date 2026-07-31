#include "albay/bitboard.h"
#include "albay/movegen.h"
#include "albay/position.h"
#include "albay/zobrist.h"
#include <array>
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <queue>
#include <string>
#include <unordered_map>
#include <vector>

using namespace albay;

namespace {
constexpr int MAX_N = 3;
constexpr int POW4[4] = {1,4,16,64};
constexpr int COMB[4] = {0,32,496,4960};
constexpr int OFF[4] = {0,0,32*4*2,32*4*2 + 496*16*2};
constexpr int DENSE_SIZE = 32*4*2 + 496*16*2 + 4960*64*2;

enum Status : uint8_t { UNKNOWN=0, LOSS=1, WIN=2 };

std::array<std::vector<uint32_t>,4> comb_masks;
std::array<std::unordered_map<uint32_t,int>,4> mask_rank;

void gen_combs_rec(int n, int start, int left, uint32_t mask) {
    if (left == 0) {
        mask_rank[n][mask] = static_cast<int>(comb_masks[n].size());
        comb_masks[n].push_back(mask);
        return;
    }
    for (int s=start; s<=32-left; ++s) gen_combs_rec(n,s+1,left-1,mask | (uint32_t(1)<<s));
}

int dense_index(const Position& p) {
    uint32_t occ = p.occupied();
    int n = std::popcount(occ);
    if (n < 1 || n > 3) return -1;
    auto it = mask_rank[n].find(occ);
    if (it == mask_rank[n].end()) return -1;
    int type_code = 0;
    int shift = 0;
    uint32_t b = occ;
    while (b) {
        int s = std::countr_zero(b); b &= b-1;
        int t;
        bool w = (p.white & (uint32_t(1)<<s)) != 0;
        bool k = (p.kings & (uint32_t(1)<<s)) != 0;
        t = w ? (k ? 1 : 0) : (k ? 3 : 2);
        type_code |= (t << shift);
        shift += 2;
    }
    int side = p.side_to_move == Color::Black ? 1 : 0;
    return OFF[n] + ((it->second * POW4[n] + type_code) * 2 + side);
}

bool decode_state(int n, uint32_t mask, int type_code, int side, Position& p) {
    p = Position{};
    uint32_t b = mask;
    int shift = 0;
    while (b) {
        int s = std::countr_zero(b); b &= b-1;
        int t = (type_code >> shift) & 3;
        shift += 2;
        uint32_t bit = uint32_t(1) << s;
        switch (t) {
            case 0:
                if (square_row(static_cast<Square>(s)) == 0) return false;
                p.white |= bit; break;
            case 1: p.white |= bit; p.kings |= bit; break;
            case 2:
                if (square_row(static_cast<Square>(s)) == 7) return false;
                p.black |= bit; break;
            case 3: p.black |= bit; p.kings |= bit; break;
        }
    }
    p.side_to_move = side ? Color::Black : Color::White;
    p.hash = compute_hash(p);
    return true;
}

struct Node {
    Position pos;
    uint16_t outdeg = 0;
};

} // namespace

int main(int argc, char** argv) {
    if (argc < 2) {
        std::cerr << "usage: tb3_generate OUT.bin [stats.json]\n";
        return 2;
    }
    init_bitboards(); init_zobrist();
    for (int n=1;n<=3;++n) gen_combs_rec(n,0,n,0);
    std::cerr << "dense size=" << DENSE_SIZE << " combs=" << comb_masks[1].size() << "," << comb_masks[2].size() << "," << comb_masks[3].size() << "\n";

    std::vector<int32_t> dense_to_compact(DENSE_SIZE, -1);
    std::vector<int32_t> compact_to_dense;
    std::vector<Node> nodes;
    nodes.reserve(500000);
    compact_to_dense.reserve(500000);

    for (int n=1;n<=3;++n) {
        int tcmax = POW4[n];
        for (int cr=0; cr<(int)comb_masks[n].size(); ++cr) {
            uint32_t mask = comb_masks[n][cr];
            for (int tc=0; tc<tcmax; ++tc) {
                for (int side=0; side<2; ++side) {
                    Position p;
                    if (!decode_state(n,mask,tc,side,p)) continue;
                    int di = OFF[n] + ((cr*tcmax + tc)*2 + side);
                    int ci = (int)nodes.size();
                    dense_to_compact[di] = ci;
                    compact_to_dense.push_back(di);
                    nodes.push_back({p,0});
                }
            }
        }
        std::cerr << "enumerated n="<<n<<" compact="<<nodes.size()<<"\n";
    }

    const int N = (int)nodes.size();
    std::vector<std::vector<int32_t>> preds(N);
    std::vector<uint16_t> remaining(N,0);
    std::vector<uint16_t> max_win_dist(N,0);
    std::vector<uint8_t> status(N,UNKNOWN);
    std::vector<uint16_t> dist(N,0);
    std::queue<int32_t> q;
    uint64_t edges=0;

    MoveList moves;
    for (int i=0;i<N;++i) {
        Position& p = nodes[i].pos;
        Bitboard us = p.pieces(p.side_to_move);
        Bitboard them = p.pieces(opposite(p.side_to_move));
        if (us == 0) {
            status[i]=LOSS; dist[i]=0; q.push(i); continue;
        }
        if (them == 0) {
            status[i]=WIN; dist[i]=0; q.push(i); continue;
        }
        generate_legal_moves(p,moves);
        if (moves.empty()) {
            status[i]=LOSS; dist[i]=0; q.push(i); continue;
        }
        nodes[i].outdeg = static_cast<uint16_t>(moves.size());
        remaining[i] = nodes[i].outdeg;
        for (const Move& m : moves) {
            UndoState u = make_move(p,m);
            int di = dense_index(p);
            unmake_move(p,m,u);
            if (di < 0 || di >= DENSE_SIZE || dense_to_compact[di] < 0) {
                std::cerr << "bad successor i="<<i<<" di="<<di<<"\n";
                return 3;
            }
            int j = dense_to_compact[di];
            preds[j].push_back(i);
            ++edges;
        }
        if ((i % 50000)==0) std::cerr << "graph "<<i<<"/"<<N<<" edges="<<edges<<"\n";
    }
    std::cerr << "graph complete nodes="<<N<<" edges="<<edges<<" seeds="<<q.size()<<"\n";

    uint64_t processed=0;
    while (!q.empty()) {
        int child=q.front(); q.pop(); ++processed;
        uint8_t cs=status[child];
        uint16_t cd=dist[child];
        for (int pred : preds[child]) {
            if (status[pred]!=UNKNOWN) continue;
            if (cs==LOSS) {
                status[pred]=WIN;
                dist[pred]=static_cast<uint16_t>(std::min<int>(65535, cd+1));
                q.push(pred);
            } else if (cs==WIN) {
                if (remaining[pred]>0) --remaining[pred];
                max_win_dist[pred]=std::max<uint16_t>(max_win_dist[pred], cd);
                if (remaining[pred]==0) {
                    status[pred]=LOSS;
                    dist[pred]=static_cast<uint16_t>(std::min<int>(65535, max_win_dist[pred]+1));
                    q.push(pred);
                }
            }
        }
        if ((processed % 50000)==0) std::cerr << "retro "<<processed<<" queue="<<q.size()<<"\n";
    }

    uint64_t wins=0, losses=0, draws=0, invalid=DENSE_SIZE-N;
    uint16_t maxd=0; uint64_t clamped=0;
    std::vector<uint8_t> packed(DENSE_SIZE,0);
    for (int i=0;i<N;++i) {
        uint8_t s=status[i];
        if (s==WIN) ++wins; else if (s==LOSS) ++losses; else ++draws;
        maxd=std::max(maxd,dist[i]);
        uint8_t d=static_cast<uint8_t>(std::min<int>(63,dist[i]));
        if (dist[i]>63) ++clamped;
        uint8_t outcome = s==WIN ? 2 : s==LOSS ? 1 : 0;
        packed[compact_to_dense[i]] = static_cast<uint8_t>((outcome<<6)|d);
    }
    std::ofstream out(argv[1],std::ios::binary);
    out.write(reinterpret_cast<const char*>(packed.data()), packed.size());
    out.close();
    std::cerr << "W="<<wins<<" L="<<losses<<" D="<<draws<<" invalid="<<invalid<<" maxd="<<maxd<<" clamp="<<clamped<<" bytes="<<packed.size()<<"\n";
    if (argc>=3) {
        std::ofstream js(argv[2]);
        js << "{\n"
           << "  \"dense_size\": "<<DENSE_SIZE<<",\n"
           << "  \"valid_states\": "<<N<<",\n"
           << "  \"edges\": "<<edges<<",\n"
           << "  \"wins\": "<<wins<<",\n"
           << "  \"losses\": "<<losses<<",\n"
           << "  \"draws\": "<<draws<<",\n"
           << "  \"invalid\": "<<invalid<<",\n"
           << "  \"max_distance\": "<<maxd<<",\n"
           << "  \"distance_clamped_states\": "<<clamped<<"\n"
           << "}\n";
    }
}
