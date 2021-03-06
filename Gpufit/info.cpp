#include "info.h"
#include <algorithm>

Info::Info() :
    n_parameters_(0),
    n_parameters_to_fit_(0),
    max_chunk_size_(0),
    max_n_iterations_(0),
    n_points_(0),
    power_of_two_n_points_(0),
    n_fits_(0),
    user_info_size_(0),
    n_fits_per_block_(0),
    model_id_(0),
    estimator_id_(0),
    max_threads_(0),
    max_blocks_(0),
    available_gpu_memory_(0)
{
}

Info::~Info(void)
{
}

void Info::set_number_of_parameters_to_fit(int const * const parameters_to_fit)
{
    n_parameters_to_fit_ = n_parameters_;

    for (int i = 0; i < n_parameters_; i++)
    {
        if (!parameters_to_fit[i])
        {
            n_parameters_to_fit_--;
        }
    }
}

void Info::set_fits_per_block(std::size_t const current_chunk_size)
{
    n_fits_per_block_ = 8;
    bool is_divisible = false;
    bool enough_threads = false;
    do 
    {
        n_fits_per_block_ /= 2;
        is_divisible = current_chunk_size % n_fits_per_block_ == 0;
        enough_threads = n_fits_per_block_ * n_points_ < max_threads_ / 4;
    } while ((!is_divisible || !enough_threads) && n_fits_per_block_ > 1);
}

void Info::set_max_chunk_size()
{
    int one_fit_memory
        = sizeof(float)
        *(2 * n_points_
        + 2 * n_parameters_
        + 2 * n_parameters_to_fit_
        + 1 * n_parameters_to_fit_*n_parameters_to_fit_
        + 1 * n_points_*n_parameters_
        + 4)
        + sizeof(int)
        * 3;

    if (use_weights_)
        one_fit_memory += sizeof(float) * n_points_;

    std::size_t tmp_chunk_size = available_gpu_memory_ / one_fit_memory;
    
    if (tmp_chunk_size == 0)
    {
        throw std::runtime_error("not enough free GPU memory available");
    }

    tmp_chunk_size = (std::min)(tmp_chunk_size, max_blocks_);

    std::size_t highest_factor = 1;

    if (n_parameters_to_fit_)
    {
        highest_factor
            = n_points_
            * n_parameters_to_fit_
            * n_parameters_to_fit_
            * sizeof(float);
    }
    else
    {
        highest_factor = n_points_ * n_parameters_;
    }

    std::size_t const highest_size_t_value
        = std::numeric_limits< std::size_t >::max();

    if (tmp_chunk_size > highest_size_t_value / highest_factor)
    {
        tmp_chunk_size = highest_size_t_value / highest_factor;
    }

    max_chunk_size_ = tmp_chunk_size;

    int i = 1;
    int const divisor = 10;
    while (tmp_chunk_size > divisor)
    {
        i *= divisor;
        tmp_chunk_size /= divisor;
    }
    max_chunk_size_ = max_chunk_size_ / i * i;
    max_chunk_size_ = std::min(max_chunk_size_, n_fits_);
}


void Info::configure()
{
    power_of_two_n_points_ = 1;
    while (power_of_two_n_points_ < n_points_)
    {
        power_of_two_n_points_ *= 2;
    }

    get_gpu_properties();
    set_max_chunk_size();
}
