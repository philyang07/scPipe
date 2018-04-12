// transcriptmapping.cpp
#include "transcriptmapping.h"

using std::string;
using std::vector;
using std::unordered_map;
using namespace Rcpp;

// anonymous namespace for file-specific functions
// functions in this namespace can only be used in this file
namespace {
    // index variables for gff3 fields
    const int SEQID = 0;
    const int SOURCE = 1;
    const int TYPE = 2;
    const int START = 3;
    const int END = 4;
    const int SCORE = 5;
    const int STRAND = 6;
    const int PHASE = 7;
    const int ATTRIBUTES  = 8;

    // file-scope globals
    string anno_source = "";

    string get_attribute(const vector<string> &all_attributes, const string &target_attribute) {
        for (const string &attr : all_attributes) {
            auto sep_loc = attr.find("=");
            string key = attr.substr(0, sep_loc);
            string val = attr.substr(sep_loc + 1);
            if (key == target_attribute) {
                return val;
            }
        }
        return "";
    }

    int get_strand(char st)
    {
        int strand = 0;
        if (st == '+')
        {
            strand = 1;
        }
        else if (st == '-')
        {
            strand = -1;
        }
        return strand;
    }

    string get_parent(const vector<string> &attributes)
    {
        for (const auto &attr : attributes)
        {
            if (attr.substr(0, 6) == "Parent")
            {
                // check for ENSEMBL notation
                if (anno_source == "ensembl")
                {
                    return attr.substr(attr.rfind(':') + 1);
                }
                else
                {
                    return attr.substr(attr.find('=') + 1);
                }
            }
        }
        return "";
    }

    string get_ID(const vector<string> &attributes)
    {
        for (const auto &attr : attributes)
        {
            if (attr.substr(0, 2) == "ID")
            {
                // check for ENSEMBL notation
                if (anno_source == "ensembl")
                {
                    return attr.substr(attr.rfind(':') + 1);
                }
                else
                {
                    return attr.substr(attr.find('=') + 1);
                }
            }
        }
        return "";
    }

    string fix_name(string chr_name)
    {
        string new_chr_name;
        if (chr_name.compare(0, 3, "chr") == 0)
        {
            return chr_name;
        }
        else if (chr_name.length() > 4) // just fix 1-22, X, Y, MT. ignore contig and ERCC
        {
            return chr_name;
        }
        else
        {
            if (chr_name == "MT")
            {
                new_chr_name = "chrM";
            }
            else
            {
                new_chr_name = "chr" + chr_name;
            }
            return new_chr_name;
        }
    }

    string get_gencode_gene_id(vector<string> attributes)
    {
        return get_attribute(attributes, "gene_id");
    }

    string get_refseq_gene_id(vector<string> attributes)
    {
        string dbxref = get_attribute(attributes, "Dbxref");

        // GeneID may be missing
        if (dbxref.find("GeneID") == std::string::npos)
        {
            return "";
        }
        
        auto start = dbxref.find("GeneID") + 7; // start after "GeneID:"
	    auto end = dbxref.find(",", start);
        auto id_length = end - start;

        return dbxref.substr(start, id_length);
    }

    string guess_anno_source(string gff3_fn) {
        std::ifstream infile(gff3_fn);
        string line;

        while (std::getline(infile, line))
        {
            if (line.find("GENCODE") != std::string::npos) {
                Rcout << "guessing annotation source: GENCODE" << "\n";
                return "gencode";
            }
            else if (line.find("1\tEnsembl") != std::string::npos)
            {
                Rcout << "guessing annotation source: ENSEMBL" << "\n";
                return "ensembl";
            }
            else if (line.find("RefSeq\tregion") != std::string::npos)
            {
                Rcout << "guessing annotation source: RefSeq" << "\n";
                return "refseq";
            }
        }

        stop("Annotation source not recognised. Current supported sources: ENSEMBL, GENCODE and RefSeq");
    }

    string get_gene_id(const vector<string> &attributes) {
        if (anno_source == "gencode")
        {
            return get_gencode_gene_id(attributes);
        }
        else if (anno_source == "refseq")
        {
            return get_refseq_gene_id(attributes);
        }
        return "";
    }

    inline const bool parent_is_gene(const vector<string> &recorded_genes, const string &parent)
    {
        return find(recorded_genes.rbegin(), recorded_genes.rend(), parent) != recorded_genes.rend();
    }

    inline const bool parent_is_known_transcript(const unordered_map<string, string> &transcript_to_gene_dict, const string &parent)
    {
        return transcript_to_gene_dict.find(parent) != transcript_to_gene_dict.end();
    }

    inline const bool is_gene(const vector<string> &fields, const vector<string> &attributes)
    {
        string type = fields[TYPE];
        if (type == "gene")
        {
            return true;
        }

        string id = get_attribute(attributes, "ID");
        if (id.find("gene:") != string::npos)
        {
            return true;
        }

        return false;
    }

    inline const bool is_exon(const vector<string> &fields, const vector<string> &attributes) {
        return fields[TYPE] == "exon";
    }

    inline const bool is_transcript(const vector<string> &fields, const vector<string> &attributes, const vector<string> &recorded_genes) {
        // assume feature is transcript is it has a gene as parent
        return parent_is_gene(recorded_genes, get_parent(attributes));
    }

    void parse_anno_entry(const bool &fix_chrname, const string &line, vector<string> &recorded_genes, unordered_map<string, unordered_map<string, Gene>> &chr_to_genes_dict, unordered_map<string, string> &transcript_to_gene_dict)
    {
        const vector<string> fields = split(line, '\t');
        const vector<string> attributes = split(fields[ATTRIBUTES], ';');

        string chr_name = fields[SEQID];
        const string parent = get_parent(attributes);
        const string type = fields[TYPE];
        const string ID = get_ID(attributes);
        const int strand = get_strand(fields[STRAND][0]);
        const int interval_start = std::atoi(fields[START].c_str());
        const int interval_end = std::atoi(fields[END].c_str());
        auto &current_chr = chr_to_genes_dict[chr_name];

        if (fix_chrname)
        {
            chr_name = fix_name(chr_name);
        }

        // DEBUG USE
        // Rcout << "Parsing: " << line << "\n";
        // Rcout << "Type: " << type << " "
        //       << "ID: " << ID << " "
        //       << "Parent: " << parent << "\n\n";
        // DEBUG USE

        string target_gene;
        if (anno_source == "ensembl")
        {
            if (is_gene(fields, attributes)) {
                recorded_genes.push_back(ID);
                return;
            }
            else if (is_transcript(fields, attributes, recorded_genes))
            {
                if (!ID.empty() && !parent.empty())
                {
                    transcript_to_gene_dict[ID] = parent;
                }
                return;
            }
            else if (is_exon(fields, attributes))
            {
                if (parent_is_known_transcript(transcript_to_gene_dict, parent))
                {
                    target_gene = transcript_to_gene_dict[parent];
                }
                else
                {
                    std::stringstream err_msg;
                    err_msg << "cannot find grandparent for exon:" << "\n";
                    err_msg << line << "\n";
                    Rcpp::stop(err_msg.str());
                }
            }
        }
        else if (anno_source == "gencode" || anno_source == "refseq")
        {
            if (type == "exon")
            {
                target_gene = get_gene_id(attributes);
            }
        }

        if (!target_gene.empty())
        {
            current_chr[target_gene].add_exon(Interval(interval_start, interval_end, strand));
            current_chr[target_gene].set_ID(target_gene);
        }

        return;
    }
}

void GeneAnnotation::parse_gff3_annotation(string gff3_fn, bool fix_chrname)
{
    std::ifstream infile(gff3_fn);

    string line;
    unordered_map<string, unordered_map<string, Gene>> chr_to_genes_dict;
    unordered_map<string, string> transcript_to_gene_dict; // store transcript - gene mapping
    vector<string> recorded_genes;

    // assigned to file-scope global
    anno_source = guess_anno_source(gff3_fn);

    // create transcript-gene mapping
    while (std::getline(infile, line))
    {
        // skip header lines
        if (line[0] == '#')
        {
            continue;
        } 

        parse_anno_entry(fix_chrname, line, recorded_genes, chr_to_genes_dict, transcript_to_gene_dict);
    }

    // push genes into annotation class member
    for (auto &chr : chr_to_genes_dict)
    {
        for (auto &gene : chr.second)
        {
            gene.second.sort_exon();
            gene_dict[chr.first].push_back(gene.second);
        }
        std::sort(gene_dict[chr.first].begin(), gene_dict[chr.first].end());
    }

}

void GeneAnnotation::parse_bed_annotation(string bed_fn, bool fix_chrname)
{
    std::ifstream infile(bed_fn);

    string line;
    unordered_map<string, unordered_map<string, Gene>> tmp_gene_dict;
    int strand = 0;
    std::vector<string> token;

    std::getline(infile, line); // skip the header
    while(std::getline(infile, line))
    {
        token = split(line, '\t');
        strand = get_strand(token[4][0]);
        if (fix_chrname)
        {
            tmp_gene_dict[fix_name(token[1])][token[0]].add_exon(Interval(std::atoi(token[2].c_str()), std::atoi(token[3].c_str()), strand));
            tmp_gene_dict[fix_name(token[1])][token[0]].set_ID(token[1]);
        }
        else
        {
            tmp_gene_dict[token[1]][token[0]].add_exon(Interval(std::atoi(token[2].c_str()), std::atoi(token[3].c_str()), strand));
            tmp_gene_dict[token[1]][token[0]].set_ID(token[1]);
        }

    }

    for (auto iter : tmp_gene_dict)
    {
        for (auto sub_iter : iter.second)
        {
            if (sub_iter.second.exon_vec.size()>1)
            {
                sub_iter.second.sort_exon();
            }
            gene_dict[iter.first].push_back(sub_iter.second);
        }
        if (gene_dict[iter.first].size()>1)
        {
            std::sort(gene_dict[iter.first].begin(), gene_dict[iter.first].end());
        }
    }
}


int GeneAnnotation::ngenes()
{
    int gene_number = 0;
    for (auto iter : gene_dict)
    {
        for (auto sub_iter : iter.second)
        {
            gene_number ++;
        }
    }

    return gene_number;
}


std::vector<string> GeneAnnotation::get_genelist()
{
    std::vector<string> gene_list;
    for (auto iter : gene_dict)
    {
        for (auto sub_iter : iter.second)
        {
            gene_list.push_back(sub_iter.gene_id);
        }
    }

    return gene_list;
}


std::ostream& operator<< (std::ostream& out, const GeneAnnotation& obj)
{
    out << "annotation statistics:" << "\n";
    for ( const auto& n : obj.gene_dict )
    {
        out << "\t" << "chromosome:[" << n.first << "] number of genes:[" << n.second.size() << "]\n";
    }
    for ( const auto& n : obj.gene_dict )
    {
        out << "first gene in chromosome " << n.first << " :" << "\n";
        out << n.second[0] << "\n";
        //break;
    }
    return out;
}


void Mapping::add_annotation(string gff3_fn, bool fix_chrname)
{
    if (gff3_fn.substr(gff3_fn.find_last_of(".") + 1) == "gff3")
    {
        Rcpp::Rcout << "adding gff3 annotation: " << gff3_fn << "\n";
        Anno.parse_gff3_annotation(gff3_fn, fix_chrname);
    }
    else
    {
        Anno.parse_bed_annotation(gff3_fn, fix_chrname);
        Rcpp::Rcout << "adding bed annotation: " << gff3_fn << "\n";
    }

}

int Mapping::map_exon(bam_hdr_t *header, bam1_t *b, string& gene_id, bool m_strand)
{
    int ret = 9999;
    int rev = bam_is_rev(b)?(-1):1;
    uint32_t* cig = bam_get_cigar(b);
    int tmp_pos = b->core.pos;
    int tmp_rest = 9999999; // distance to end pos
    int tmp_ret;
    string tmp_id;
    gene_id = "";

    for (int c=0; c<b->core.n_cigar; c++)
    {
        tmp_ret = 9999;
        // *   bit 1 set if the cigar operation consumes the query
        // *   bit 2 set if the cigar operation consumes the reference
        if (((bam_cigar_type(cig[c]) >> 0) & 1) && ((bam_cigar_type(cig[c]) >> 1) & 1))
        {
            Interval it = Interval(tmp_pos, tmp_pos+bam_cigar_oplen(cig[c]), rev);
            auto &gene_list = Anno.gene_dict[header->target_name[b->core.tid]];
            auto iter = std::equal_range(gene_list.begin(), gene_list.end(), it);
            if ((iter.second - iter.first) == 0)
            {
                tmp_ret = tmp_ret>3?3:tmp_ret;
            }
            else
            {
                tmp_id = "";
                for (auto i = iter.first; i < iter.second; ++i)
                {
                    if (i->in_exon(it, m_strand))
                    {
                        if (tmp_id != "")
                        {
                            if (tmp_id != i->gene_id)
                            {
                                tmp_ret = 1; // ambiguous mapping
                                break;
                            }
                            else
                            {
                                // update the distance to end pos
                                tmp_rest = tmp_rest<(i->distance_to_end(it))?tmp_rest:i->distance_to_end(it);
                            }
                        }
                        else
                        {
                            tmp_id = i->gene_id;
                            tmp_ret = 0;
                            tmp_rest = i->distance_to_end(it);
                        }
                    }
                    else if ((it > *i) || (it < *i))
                    {
                        tmp_ret = tmp_ret>=3?3:tmp_ret;
                    }
                    else
                    {
                        tmp_ret = tmp_ret>=2?2:tmp_ret;
                    }
                }
            }

            tmp_pos = tmp_pos+bam_cigar_oplen(cig[c]);
            if (ret == 0 && tmp_ret == 0)
            {
                if (gene_id != "" && gene_id != tmp_id)
                {
                    ret = 1; // still ambiguous
                    break;
                }
            }
            else if (tmp_ret == 0)
            {
                ret = 0;
                gene_id = tmp_id;
            }
            else
            {
                ret = ret<tmp_ret?ret:tmp_ret; // choose the smallest
            }
        }
        else if (!((bam_cigar_type(cig[c]) >> 0) & 1) && ((bam_cigar_type(cig[c]) >> 1) & 1))
        {
            tmp_pos = tmp_pos+bam_cigar_oplen(cig[c]);
        }
    }
    if (ret == 0)
    {
        return -tmp_rest;
    }
    else
    {
        // return codes:
        // 0: unique map to exon
        // 1: ambiguous map to multiple exon
        // 2: map to intron
        // 3: not mapped
        return ret;
    }
}

namespace {
    void report_every_3_mins(std::atomic<unsigned long long> &cnt, std::atomic<bool> &running) {
        Timer timer;
        timer.start();

        do {
            // sleep thread for a total of 3 minutes (180 seconds)
            // wake up at shorter intervals to check if process has stopped running
            for (int i = 0; i < 36; i++)
            {
                std::this_thread::sleep_for(std::chrono::seconds(5));
                if (!running)
                {
                    break;
                }
            }

            std::cout
                << cnt << " reads processed" << ", "
                << cnt / timer.seconds_elapsed() / 1000 << "k reads/sec" << "\n";
        } while (running);
    }
}

void Mapping::parse_align(string fn, string fn_out, bool m_strand, string map_tag, string gene_tag, string cellular_tag, string molecular_tag, int bc_len, int UMI_len)
{
    int unaligned = 0;
    int ret;

    check_file_exists(fn); // htslib does not check if file exist so we do it manually

    // open files
    bam1_t *b = bam_init1();
    BGZF *fp = bgzf_open(fn.c_str(), "r"); // input file
    samFile *of = sam_open(fn_out.c_str(), "wb"); // output file

    bam_hdr_t *header = bam_hdr_read(fp);
    sam_hdr_write(of, header);

    string gene_id;
    int tmp_c[4] = {0,0,0,0};

    bool found_any = false;
    for (int i = 0; i < header->n_targets; ++i)
    {
        if (Anno.gene_dict.end() == Anno.gene_dict.find(header->target_name[i]))
        {
            Rcpp::Rcout << header->target_name[i] << " not found in exon annotation." << "\n";
        }
        else
        {
            found_any = true;
        }

    }
    if (!found_any)
    {
        std::stringstream err_msg;
        err_msg << "ERROR: The annotation and .bam file contains different chromosome." << "\n";
        Rcpp::stop(err_msg.str());
    }
    // for moving barcode and UMI from sequence name to bam tags
    const char * g_ptr = gene_tag.c_str();
    const char * c_ptr = cellular_tag.c_str();
    const char * m_ptr = molecular_tag.c_str();
    const char * a_ptr = map_tag.c_str();
    char buf[999] = ""; // assume the length of barcode or UMI is less than 999
    std::atomic<unsigned long long> cnt{0};
    std::atomic<bool> running{true};

    Rcout << "updating progress every 3 minutes..." << "\n";
    // spawn thread to report progress every 3 minutes
    std::thread reporter_thread(
        [&cnt, &running]() {
            report_every_3_mins(cnt, running);
        }
    );

    while (bam_read1(fp, b) >= 0)
    {
        if (__DEBUG)
        {
            if (cnt % 1000000 == 0)
            {
                Rcpp::Rcout << "number of read processed:" << cnt << "\n";
                Rcpp::Rcout << tmp_c[0] <<"\t"<< tmp_c[1] <<"\t"<<tmp_c[2] <<"\t"<<tmp_c[3] <<"\t" << "\n";
            }
        }
        cnt++;

        if ((b->core.flag&BAM_FUNMAP) > 0)
        {
            unaligned++;
            ret = 4;
        }
        else
        {
            //  chromosome not found in annotation:
            if (Anno.gene_dict.end() == Anno.gene_dict.find(header->target_name[b->core.tid]))
            {
                ret = 3;
            }
            else
            {
                ret = map_exon(header, b, gene_id, m_strand);
            }
            if (ret <= 0)
            {
                tmp_c[0]++;
                bam_aux_append(b, g_ptr, 'Z', gene_id.size()+1, (uint8_t*)gene_id.c_str());
            }
            else
            {
                tmp_c[ret]++;
            }
        }
        if (bc_len > 0)
        {
            memcpy(buf, bam_get_qname(b), bc_len * sizeof(char));
            buf[bc_len] = '\0';
            bam_aux_append(b, c_ptr, 'Z', bc_len+1, (uint8_t*)buf);
        }
        if (UMI_len > 0)
        {
            memcpy(buf, bam_get_qname(b)+bc_len+1, UMI_len * sizeof(char)); // `+1` to add separator
            buf[UMI_len] = '\0';
            bam_aux_append(b, m_ptr, 'Z', UMI_len+1, (uint8_t*)buf);
        }

        bam_aux_append(b, a_ptr, 'i', sizeof(uint32_t), (uint8_t*)&ret);

        int re = sam_write1(of, header, b);
        if (re < 0)
        {
            std::stringstream err_msg;
            err_msg << "fail to write the bam file: " << bam_get_qname(b) << "\n";
            err_msg << "return code: " << re << "\n";
            Rcpp::stop(err_msg.str());
        }
    }

    running = false;
    reporter_thread.join();

    Rcpp::Rcout << "\t" << "number of read processed: " << cnt << "\n";
    Rcpp::Rcout << "\t" << "unique map to exon: " << tmp_c[0]
        << "(" << std::fixed << std::setprecision(2) << 100. * tmp_c[0]/cnt << "%)" << "\n";

    Rcpp::Rcout << "\t" << "ambiguous map to multiple exon: " << tmp_c[1]
        << "("  << std::fixed << std::setprecision(2) << 100. * tmp_c[1]/cnt << "%)" << "\n";

    Rcpp::Rcout << "\t" << "map to intron: " << tmp_c[2]
        << "(" << std::fixed << std::setprecision(2) << 100. * tmp_c[2]/cnt << "%)" << "\n";

    Rcpp::Rcout << "\t" << "not mapped: " << tmp_c[2]
        << "("  << std::fixed << std::setprecision(2) << 100. * tmp_c[3]/cnt << "%)" << "\n";
        
    Rcpp::Rcout << "\t" << "unaligned: " << unaligned
        << "(" << std::fixed << std::setprecision(2) << 100. * unaligned/cnt << "%)" << "\n";
    sam_close(of);
    bgzf_close(fp);
}
