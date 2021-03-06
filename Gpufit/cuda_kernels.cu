#include "gpufit.h"
#include "cuda_kernels.cuh"
#include "definitions.h"
#include "linear_1d.cuh"
#include "gauss_1d.cuh"
#include "gauss_2d.cuh"
#include "gauss_2d_elliptic.cuh"
#include "gauss_2d_rotated.cuh"
#include "cauchy_2d_elliptic.cuh"
#include "lse.cuh"
#include "mle.cuh"

/* Description of the cuda_calc_curve_values function
* ===================================================
*
* This function calls one of the fitting curve functions depending on the input
* parameter model_id. The fitting curve function calculates the values of
* the fitting curves and its partial derivatives with respect to the fitting
* curve parameters. Multiple fits are calculated in parallel.
*
* Parameters:
*
* parameters: An input vector of concatenated sets of model parameters.
*
* n_fits: The number of fits.
*
* n_points: The number of data points per fit.
*
* n_parameters: The number of curve parameters.
*
* finished: An input vector which allows the calculation to be skipped for single
*           fits.
*
* values: An output vector of concatenated sets of model function values.
*
* derivatives: An output vector of concatenated sets of model function partial
*              derivatives.
*
* n_fits_per_block: The number of fits calculated by each threadblock.
*
* model_id: The fitting model ID.
*
* chunk_index: The chunk index.
*
* user_info: An input vector containing user information.
*
* user_info_size: The number of elements in user_info.
*
* Calling the cuda_calc_curve_values function
* ===========================================
*
* When calling the function, the blocks and threads must be set up correctly,
* as shown in the following example code.
*
*   dim3  threads(1, 1, 1);
*   dim3  blocks(1, 1, 1);
*
*   threads.x = n_points * n_fits_per_block;
*   blocks.x = n_fits / n_fits_per_block;
*
*   cuda_calc_curve_values<<< blocks, threads >>>(
*       parameters,
*       n_points,
*       n_parameters,
*       finished,
*       values,
*       derivatives,
*       n_fits_per_block,
*       model_id,
*       chunk_index,
*       user_info,
*       user_info_size);
*
*/

__global__ void cuda_calc_curve_values(
    float const * parameters,
    int const n_fits,
    int const n_points,
    int const n_parameters,
    int const * finished,
    float * values,
    float * derivatives,
    int const n_fits_per_block,
    int const model_id,
    int const chunk_index,
    char * user_info,
    std::size_t const user_info_size)
{
    int const fit_in_block = threadIdx.x / n_points;
    int const point_index = threadIdx.x - fit_in_block * n_points;
    int const fit_index = blockIdx.x * n_fits_per_block + fit_in_block;

    if (finished[fit_index])
        return;
    if (point_index >= n_points)
        return;

    if (model_id == GAUSS_1D)
        calculate_gauss1d(parameters, n_fits, n_points, n_parameters, values, derivatives, chunk_index, user_info, user_info_size);
    else if (model_id == GAUSS_2D)
        calculate_gauss2d(parameters, n_fits, n_points, n_parameters, values, derivatives, chunk_index, user_info, user_info_size);
    else if (model_id == GAUSS_2D_ELLIPTIC)
        calculate_gauss2delliptic(parameters, n_fits, n_points, n_parameters, values, derivatives, chunk_index, user_info, user_info_size);
    else if (model_id == GAUSS_2D_ROTATED)
        calculate_gauss2drotated(parameters, n_fits, n_points, n_parameters, values, derivatives, chunk_index, user_info, user_info_size);
    else if (model_id == CAUCHY_2D_ELLIPTIC)
        calculate_cauchy2delliptic(parameters, n_fits, n_points, n_parameters, values, derivatives, chunk_index, user_info, user_info_size);
    else if (model_id == LINEAR_1D)
        calculate_linear1d(parameters, n_fits, n_points, n_parameters, values, derivatives, chunk_index, user_info, user_info_size);
}

/* Description of the sum_up_floats function
* ==========================================
*
* This function sums up a vector of float values and stores the result at the
* first place of the vector.
*
* Parameters:
*
* shared_array: An input vector of float values. The vector must be stored
*               on the shared memory of the GPU. The size of this vector must be a
*               power of two. Use zero padding to extend it to the next highest
*               power of 2 greater than the number of elements.
*
* size: The number of elements in the input vector considering zero padding.
*
* Calling the sum_up_floats function
* ==================================
*
* This __device__ function can be only called from a __global__ function or
* an other __device__ function. When calling the function, the blocks and threads
* of the __global__ function must be set up correctly, as shown in the following
* example code.
*
*   dim3  threads(1, 1, 1);
*   dim3  blocks(1, 1, 1);
*
*   threads.x = size * vectors_per_block;
*   blocks.x = n_vectors / vectors_per_block;
*
*   global_function<<< blocks,threads >>>(parameter1, ...);
*
*/

__device__ void sum_up_floats(volatile float* shared_array, int const size)
{
    int const fit_in_block = threadIdx.x / size;
    int const point_index = threadIdx.x - (fit_in_block*size);

    int current_n_points = size >> 1;
    __syncthreads();
    while (current_n_points)
    {
        if (point_index < current_n_points)
        {
            shared_array[point_index] += shared_array[point_index + current_n_points];
        }
        current_n_points >>= 1;
        __syncthreads();
    }
}

/* Description of the cuda_calculate_chi_squares function
* ========================================================
*
* This function calculates the chi-square values calling a __device__ function.
* The calcluation is performed for multiple fits in parallel.
*
* Parameters:
*
* chi_squares: An output vector of concatenated chi-square values.
*
* states: An output vector of values which indicate whether the fitting process
*         was carreid out correctly or which problem occurred. In this function
*         it is only used for MLE. It is set to 3 if a fitting curve value is
*         negative. This vector includes the states for multiple fits.
*
* iteration_falied: An output vector which indicates whether the chi-square values
*                   calculated by the current iteration decreased compared to the
*                   previous iteration.
*
* prev_chi_squares: An input vector of concatenated chi-square values calculated
*                   by the previous iteration.
*
* data: An input vector of data for multiple fits
*
* values: An input vector of concatenated sets of model function values.
*
* weight: An input vector of values for weighting chi-square, gradient and hessian,
*         while using LSE
*
* n_points: The number of data points per fit.
*
* estimator_id: The estimator ID.
*
* finished: An input vector which allows the calculation to be skipped for single
*           fits.
*
* n_fits_per_block: The number of fits calculated by each thread block.
*
* user_info: An input vector containing user information.
*
* user_info_size: The number of elements in user_info.
*
* Calling the cuda_calculate_chi_squares function
* ================================================
*
* When calling the function, the blocks and threads must be set up correctly,
* as shown in the following example code.
*
*   dim3  threads(1, 1, 1);
*   dim3  blocks(1, 1, 1);
*
*   threads.x = power_of_two_n_points * n_fits_per_block;
*   blocks.x = n_fits / n_fits_per_block;
*
*   cuda_calculate_chi_squares<<< blocks, threads >>>(
*       chi_squares,
*       states,
*       iteration_falied,
*       prev_chi_squares,
*       data,
*       values,
*       weight,
*       n_points,
*       estimator_id,
*       finished,
*       n_fits_per_block,
*       user_info,
*       user_info_size);
*
*/

__global__ void cuda_calculate_chi_squares(
    float * chi_squares,
    int * states,
    int * iteration_falied,
    float const * prev_chi_squares,
    float const * data,
    float const * values,
    float const * weights,
    int const n_points,
    int const estimator_id,
    int const * finished,
    int const n_fits_per_block,
    char * user_info,
    std::size_t const user_info_size)
{
    int const shared_size = blockDim.x / n_fits_per_block;
    int const fit_in_block = threadIdx.x / shared_size;
    int const fit_index = blockIdx.x * n_fits_per_block + fit_in_block;
    int const point_index = threadIdx.x - fit_in_block * shared_size;
    int const first_point = fit_index * n_points;

    if (finished[fit_index])
    {
        return;
    }

    float const * current_data = &data[first_point];
    float const * current_weight = weights ? &weights[first_point] : NULL;
    float const * current_value  = &values[first_point];
    int * current_state = &states[fit_index];

    extern __shared__ float extern_array[];
    
    volatile float * shared_chi_square = &extern_array[fit_in_block*shared_size];
    
    if (point_index >= n_points)
    {
        shared_chi_square[point_index] = 0.f;
    }

    if (point_index < n_points)
    {
        if (estimator_id == LSE)
        {
            calculate_chi_square_lse(
                shared_chi_square,
                point_index,
                current_data,
                current_value,
                current_weight,
                current_state,
                user_info,
                user_info_size);
        }
        else if (estimator_id == MLE)
        {
            calculate_chi_square_mle(
                shared_chi_square,
                point_index,
                current_data,
                current_value,
                current_weight,
                current_state,
                user_info,
                user_info_size);
        }
    }
    sum_up_floats(shared_chi_square, shared_size);
    chi_squares[fit_index] = shared_chi_square[0];


    bool const prev_chi_squares_initialized = prev_chi_squares[fit_index] != 0;
    bool const chi_square_increased = (chi_squares[fit_index] >= prev_chi_squares[fit_index]);
    if (prev_chi_squares_initialized && chi_square_increased)
    {
        iteration_falied[fit_index] = 1;
    }
    else
    {
        iteration_falied[fit_index] = 0;
    }
}

/* Description of the cuda_calculate_gradients function
* ========================================================
*
* This function calculates the gradient values of the chi-square function calling
* a __device__ function. The calcluation is performed for multiple fits in parallel.
*
* Parameters:
*
* gradients: An output vector of concatenated sets of gradient vector values.
*
* data: An input vector of data for multiple fits
*
* values: An input vector of concatenated sets of model function values.
*
* derivatives: An input vector of concatenated sets of model function partial
*              derivatives.
*
* weight: An input vector of values for weighting chi-square, gradient and hessian,
*         while using LSE
*
* n_points: The number of data points per fit.
*
* n_parameters: The number of fitting curve parameters.
*
* n_parameters_to_fit: The number of fitting curve parameters, that are not held
*                      fixed.
*
* parameters_to_fit_indices: An input vector of indices of fitting curve parameters,
*                            that are not held fixed.
*
* estimator_id: The estimator ID.
*
* finished: An input vector which allows the calculation to be skipped for single
*           fits.
*
* skip: An input vector which allows the calculation to be skipped for single fits.
*
* n_fits_per_block: The number of fits calculated by each thread block.
*
* user_info: An input vector containing user information.
*
* user_info_size: The number of elements in user_info.
*
* Calling the cuda_calculate_gradients function
* ================================================
*
* When calling the function, the blocks and threads must be set up correctly,
* as shown in the following example code.
*
*   dim3  threads(1, 1, 1);
*   dim3  blocks(1, 1, 1);
*
*   threads.x = power_of_two_n_points * n_fits_per_block;
*   blocks.x = n_fits / n_fits_per_block;
*
*   cuda_calculate_gradients<<< blocks, threads >>>(
*       gradients,
*       data,
*       values,
*       derivatives,
*       weight,
*       n_points,
*       n_parameters,
*       n_parameters_to_fit,
*       parameters_to_fit_indices,
*       estimator_id,
*       finished,
*       skip,
*       n_fits_per_block,
*       user_info,
*       user_info_size);
*
*/

__global__ void cuda_calculate_gradients(
    float * gradients,
    float const * data,
    float const * values,
    float const * derivatives,
    float const * weights,
    int const n_points,
    int const n_parameters,
    int const n_parameters_to_fit,
    int const * parameters_to_fit_indices,
    int const estimator_id,
    int const * finished,
    int const * skip,
    int const n_fits_per_block,
    char * user_info,
    std::size_t const user_info_size)
{
    int const shared_size = blockDim.x / n_fits_per_block;
    int const fit_in_block = threadIdx.x / shared_size;
    int const fit_index = blockIdx.x * n_fits_per_block + fit_in_block;
    int const point_index = threadIdx.x - fit_in_block * shared_size;
    int const first_point = fit_index * n_points;

    if (finished[fit_index] || skip[fit_index])
    {
        return;
    }

    float const * current_data = &data[first_point];
    float const * current_weight = weights ? &weights[first_point] : NULL;
    float const * current_derivative = &derivatives[first_point * n_parameters];
    float const * current_value = &values[first_point];

    extern __shared__ float extern_array[];

    volatile float * shared_gradient = &extern_array[fit_in_block * shared_size];

    if (point_index >= n_points)
    {
        shared_gradient[point_index] = 0.f;
    }

    for (int parameter_index = 0; parameter_index < n_parameters_to_fit; parameter_index++)
    {
        if (point_index < n_points)
        {
            int const derivative_index  = parameters_to_fit_indices[parameter_index] * n_points + point_index;

            if (estimator_id == LSE)
            {
                calculate_gradient_lse(
                    shared_gradient,
                    point_index,
                    derivative_index,
                    current_data,
                    current_value,
                    current_derivative,
                    current_weight,
                    user_info,
                    user_info_size);
            }
            else if (estimator_id == MLE)
            {
                calculate_gradient_mle(
                    shared_gradient,
                    point_index,
                    derivative_index,
                    current_data,
                    current_value,
                    current_derivative,
                    current_weight,
                    user_info,
                    user_info_size);
            }
        }
        sum_up_floats(shared_gradient, shared_size);
        gradients[fit_index * n_parameters_to_fit + parameter_index] = shared_gradient[0];
    }
}

/* Description of the cuda_calculate_hessians function
* ========================================================
*
* This function calculates the hessian matrix values of the chi-square function
* calling a __device__ functions. The calcluation is performed for multiple fits
* in parallel.
*
* Parameters:
*
* hessians: An output vector of concatenated sets of hessian matrix values.
*
* data: An input vector of data for multiple fits
*
* values: An input vector of concatenated sets of model function values.
*
* derivatives: An input vector of concatenated sets of model function partial
*              derivatives.
*
* weight: An input vector of values for weighting chi-square, gradient and hessian,
*         while using LSE
*
* n_points: The number of data points per fit.
*
* n_parameters: The number of fitting curve parameters.
*
* n_parameters_to_fit: The number of fitting curve parameters, that are not held
*                      fixed.
*
* parameters_to_fit_indices: An input vector of indices of fitting curve parameters,
*                            that are not held fixed.
*
* estimator_id: The estimator ID.
*
* skip: An input vector which allows the calculation to be skipped for single fits.
*
* finished: An input vector which allows the calculation to be skipped for single
*           fits.
*
* user_info: An input vector containing user information.
*
* user_info_size: The number of elements in user_info.
*
* Calling the cuda_calculate_hessians function
* ================================================
*
* When calling the function, the blocks and threads must be set up correctly,
* as shown in the following example code.
*
*   dim3  threads(1, 1, 1);
*   dim3  blocks(1, 1, 1);
*
*   threads.x = n_parameters_to_fit;
*   threads.y = n_parameters_to_fit;
*   blocks.x = n_fits;
*
*   cuda_calculate_hessians<<< blocks, threads >>>(
*       hessians,
*       data,
*       values,
*       derivatives,
*       weight,
*       n_points,
*       n_parameters,
*       n_parameters_to_fit,
*       parameters_to_fit_indices,
*       estimator_id,
*       skip,
*       finished,
*       user_info,
*       user_info_size);
*
*/

__global__ void cuda_calculate_hessians(
    float * hessians,
    float const * data,
    float const * values,
    float const * derivatives,
    float const * weights,
    int const n_points,
    int const n_parameters,
    int const n_parameters_to_fit,
    int const * parameters_to_fit_indices,
    int const estimator_id,
    int const * skip,
    int const * finished,
    char * user_info,
    std::size_t const user_info_size)
{
    int const fit_index = blockIdx.x;
    int const first_point = fit_index * n_points;

    int const parameter_index_i = threadIdx.x;
    int const parameter_index_j = threadIdx.y;

    if (finished[fit_index] || skip[fit_index])
    {
        return;
    }

    float * current_hessian = &hessians[fit_index * n_parameters_to_fit * n_parameters_to_fit];
    float const * current_data = &data[first_point];
    float const * current_weight = weights ? &weights[first_point] : NULL;
    float const * current_derivative = &derivatives[first_point*n_parameters];
    float const * current_value = &values[first_point];

    int const hessian_index_ij = parameter_index_i * n_parameters_to_fit + parameter_index_j;
    int const derivative_index_i = parameters_to_fit_indices[parameter_index_i] * n_points;
    int const derivative_index_j = parameters_to_fit_indices[parameter_index_j] * n_points;

    double sum = 0.0;
    for (int point_index = 0; point_index < n_points; point_index++)
    {
        if (estimator_id == LSE)
        {
            calculate_hessian_lse(
                &sum,
                point_index,
                derivative_index_i + point_index,
                derivative_index_j + point_index,
                current_data,
                current_value,
                current_derivative,
                current_weight,
                user_info,
                user_info_size);
        }
        else if (estimator_id == MLE)
        {
            calculate_hessian_mle(
                &sum,
                point_index,
                derivative_index_i + point_index,
                derivative_index_j + point_index,
                current_data,
                current_value,
                current_derivative,
                current_weight,
                user_info,
                user_info_size);
        }
    }
    current_hessian[hessian_index_ij] = sum;
}

/* Description of the cuda_modify_step_widths function
* ====================================================
*
* This function midifies the diagonal elements of the hessian matrices by multiplying
* them by the factor (1+ lambda). This operation controls the step widths of the
* iteration. If the last iteration failed, befor modifying the hessian, the diagonal
* elements of the hessian are calculated back to represent unmodified values.
*
* hessians: An input and output vector of hessian matrices, which are modified by
*           the lambda values.
*
* lambdas: An input vector of values for modifying the hessians.
*
* n_parameters: The number of fitting curve parameters.
*
* iteration_falied: An input vector which indicates whether the previous iteration
*                   failed.
*
* finished: An input vector which allows the calculation to be skipped for single fits.
*
* n_fits_per_block: The number of fits calculated by each thread block.
*
* Calling the cuda_modify_step_widths function
* ============================================
*
* When calling the function, the blocks and threads must be set up correctly,
* as shown in the following example code.
*
*   dim3  threads(1, 1, 1);
*   dim3  blocks(1, 1, 1);
*
*   threads.x = n_parameters_to_fit * n_fits_per_block;
*   blocks.x = n_fits / n_fits_per_block;
*
*   cuda_modify_step_width<<< blocks, threads >>>(
*       hessians,
*       lambdas,
*       n_parameters,
*       iteration_failed,
*       finished,
*       n_fits_per_block);
*
*/
        
__global__ void cuda_modify_step_widths(
    float * hessians,
    float const * lambdas,
    unsigned int const n_parameters,
    int const * iteration_failed,
    int const * finished,
    int const n_fits_per_block)
{
    int const shared_size = blockDim.x / n_fits_per_block;
    int const fit_in_block = threadIdx.x / shared_size;
    int const parameter_index = threadIdx.x - fit_in_block * shared_size;
    int const fit_index = blockIdx.x * n_fits_per_block + fit_in_block;

    if (finished[fit_index])
    {
        return;
    }

    float * current_hessian = &hessians[fit_index * n_parameters * n_parameters];

    if (iteration_failed[fit_index])
    {
        current_hessian[parameter_index * n_parameters + parameter_index]
            = current_hessian[parameter_index * n_parameters + parameter_index]
            / (1.0f + lambdas[fit_index] / 10.f);
    }
    
    current_hessian[parameter_index * n_parameters + parameter_index]
        = current_hessian[parameter_index * n_parameters + parameter_index]
        * (1.0f + lambdas[fit_index]);
}

/* Description of the cuda_update_parameters function
* ===================================================
*
* This function stores the fitting curve parameter values in prev_parameters and
* updates them after each iteration.
*
* Parameters:
*
* deltas: An input vector of concatenated delta values, which are added to the
*         model parameters.
*
* parameters: An input and output vector of concatenated sets of model
*             parameters.
*
* n_parameters_to_fit: The number of fitted curve parameters.
*
* parameters_to_fit_indices: The indices of fitted curve parameters.
*
* finished: An input vector which allows the calculation to be skipped for single fits.
*
* n_fits_per_block: The number of fits calculated by each threadblock.
*
* Calling the cuda_update_parameters function
* ===========================================
*
* When calling the function, the blocks and threads must be set up correctly,
* as shown in the following example code.
*
*   dim3  threads(1, 1, 1);
*   dim3  blocks(1, 1, 1);
*
*   threads.x = n_parameters * n_fits_per_block;
*   blocks.x = n_fits / n_fits_per_block;
*
*   cuda_update_parameters<<< blocks, threads >>>(
*       deltas,
*       parameters,
*       n_parameters_to_fit,
*       parameters_to_fit_indices,
*       finished,
*       n_fits_per_block);
*
*/
    
__global__ void cuda_update_parameters(
    float * parameters,
    float * prev_parameters,
    float const * deltas,
    int const n_parameters_to_fit,
    int const * parameters_to_fit_indices,
    int const * finished,
    int const n_fits_per_block)
{
    int const n_parameters = blockDim.x / n_fits_per_block;
    int const fit_in_block = threadIdx.x / n_parameters;
    int const parameter_index = threadIdx.x - fit_in_block * n_parameters;
    int const fit_index = blockIdx.x * n_fits_per_block + fit_in_block;

    float * current_parameters = &parameters[fit_index * n_parameters];
    float * current_prev_parameters = &prev_parameters[fit_index * n_parameters];

    current_prev_parameters[parameter_index] = current_parameters[parameter_index];

    if (finished[fit_index])
    {
        return;
    }

    if (parameter_index >= n_parameters_to_fit)
    {
        return;
    }

    float const * current_deltas = &deltas[fit_index * n_parameters_to_fit];

    current_parameters[parameters_to_fit_indices[parameter_index]] += current_deltas[parameter_index];
}

/* Description of the cuda_update_state_after_gaussjordan function
* ================================================================
*
* This function interprets the singular flag vector of the Gauss Jordan function
* according to this LM implementation.
*
* Parameters:
*
* n_fits: The number of fits.
*
* singular_checks: An input vector used to report whether a fit is singular.  
*
* states: An output vector of values which indicate whether the fitting process
*         was carreid out correctly or which problem occurred. If a hessian
*         matrix of a fit is singular, it is set to 2.
*
* Calling the cuda_update_state_after_gaussjordan function
* ========================================================
*
* When calling the function, the blocks and threads must be set up correctly,
* as shown in the following example code.
*
*   dim3  threads(1, 1, 1);
*   dim3  blocks(1, 1, 1);
*
*   int const example_value = 256;
*
*   threads.x = min(n_fits, example_value);
*   blocks.x = int(ceil(float(n_fits) / float(threads.x)));
*
*   cuda_update_state_after_gaussjordan<<< blocks, threads >>>(
*       n_fits,
*       singular_checks,
*       states);
*
*/


__global__ void cuda_update_state_after_gaussjordan(
    int const n_fits,
    int const * singular_checks,
    int * states)
{
    int const fit_index = blockIdx.x * blockDim.x + threadIdx.x;

    if (fit_index >= n_fits)
    {
        return;
    }

    if (singular_checks[fit_index] == 1)
    {
        states[fit_index] = STATE_SINGULAR_HESSIAN;
    }

}

/* Description of the cuda_check_for_convergence function
* =======================================================
*
* This function checks after each iteration whether the fits are converged or not.
* It also checks whether the set maximum number of iterations is reached.
*
* Parameters:
*
* finished: An input and output vector which allows the calculation to be skipped
*           for single fits.
*
* tolerance: The tolerance value for the convergence set by user.
*
* states: An output vector of values which indicate whether the fitting process
*         was carreid out correctly or which problem occurred. If the maximum
*         number of iterationsis reached without converging, it is set to 1. If
*         the fit converged it keeps its initial value of 0.
*
* chi_squares: An input vector of chi-square values for multiple fits. Used for the
*             convergence check.
*
* prev_chi_squares: An input vector of chi-square values for multiple fits calculated
*                  in the previous iteration. Used for the convergence check.
*
* iteration: The value of the current iteration. It is compared to the value
*            of the maximum number of iteration set by user.
*
* max_n_iterations: The maximum number of iterations set by user.
*
* n_fits: The number of fits.
*
* Calling the cuda_check_for_convergence function
* ===============================================
*
* When calling the function, the blocks and threads must be set up correctly,
* as shown in the following example code.
*
*   dim3  threads(1, 1, 1);
*   dim3  blocks(1, 1, 1);
*
*   int const example_value = 256;
*
*   threads.x = min(n_fits, example_value);
*   blocks.x = int(ceil(float(n_fits) / float(threads.x)));
*
*   cuda_check_for_convergence<<< blocks, threads >>>(
*       finished,
*       tolerance,
*       states,
*       chi_squares,
*       prev_chi_squares,
*       iteration,
*       max_n_iterations,
*       n_fits);
*
*/

__global__ void cuda_check_for_convergence(
    int * finished,
    float const tolerance,
    int * states,
    float const * chi_squares,
    float const * prev_chi_squares,
    int const iteration,
    int const max_n_iterations,
    int const n_fits)
{
    int const fit_index = blockIdx.x * blockDim.x + threadIdx.x;

    if (fit_index >= n_fits)
    {
        return;
    }

    if (finished[fit_index])
    {
        return;
    }

    int const fit_found = abs(chi_squares[fit_index] - prev_chi_squares[fit_index])  < tolerance * fmaxf(1, chi_squares[fit_index]);

    int const max_n_iterations_reached = iteration == max_n_iterations - 1;

    if (fit_found)
    {
        finished[fit_index] = 1;
    }
    else if (max_n_iterations_reached)
    {
        states[fit_index] = STATE_MAX_ITERATION;
    }
}

/* Description of the cuda_evaluate_iteration function
* ====================================================
*
* This function evaluates the current iteration.
*   - It marks a fit as finished if a problem occured.
*   - It saves the needed number of iterations if a fit finished.
*   - It checks if all fits finished
*
* Parameters:
*
* all_finished: An output flag, that indicates whether all fits finished.
*
* n_iterations: An output vector of needed iterations for each fit.
*
* finished: An input and output  vector which allows the evaluation to be skipped
*           for single fits
*
* iteration: The values of the current iteration.
*
* states: An input vector of values which indicate whether the fitting process
*         was carreid out correctly or which problem occurred.
*
* n_fits: The number of fits.
*
* Calling the cuda_evaluate_iteration function
* ============================================
*
* When calling the function, the blocks and threads must be set up correctly,
* as shown in the following example code.
*
*   dim3  threads(1, 1, 1);
*   dim3  blocks(1, 1, 1);
*
*   int const example_value = 256;
*
*   threads.x = min(n_fits, example_value);
*   blocks.x = int(ceil(float(n_fits) / float(threads.x)));
*
*   cuda_evaluate_iteration<<< blocks, threads >>>(
*       all_finished,
*       n_iterations,
*       finished,
*       iteration,
*       states,
*       n_fits)
*
*/

__global__ void cuda_evaluate_iteration(
    int * all_finished,
    int * n_iterations,
    int * finished,
    int const iteration,
    int const * states,
    int const n_fits)
{
    int const fit_index = blockIdx.x * blockDim.x + threadIdx.x;

    if (fit_index >= n_fits)
    {
        return;
    }

    if (states[fit_index] != STATE_CONVERGED)
    {
        finished[fit_index] = 1;
    }

    if (finished[fit_index] && n_iterations[fit_index] == 0)
    {
        n_iterations[fit_index] = iteration + 1;
    }

    if (!finished[fit_index])
    {
        * all_finished = 0;
    }
}

/* Description of the cuda_prepare_next_iteration function
* ========================================================
*
* This function prepares the next iteration. It either updates chi-square values
* or sets chi-squares and curve parameters to previous values. This function also
* updates lambda values.
*
* Parameters:
*
* lambdas: An output vector of values which control the step width by modifying
*          the diagonal elements of the hessian matrices.
*
* chi_squares: An input vector of chi-square values for multiple fits.
*
* prev_chi_squares: An input vector of chi-square values for multiple fits calculated
*                  in the previous iteration.
*
* parameters: An output vector of concatenated sets of model parameters.
*
* prev_parameters: An input vector of concatenated sets of model parameters
*                  calculated in the previous iteration.
*
* n_fits: The number of fits.
*
* n_parameters: The number of fitting curve parameters.
*
* Calling the cuda_prepare_next_iteration function
* ================================================
*
* When calling the function, the blocks and threads must be set up correctly,
* as shown in the following example code.
*
*   dim3  threads(1, 1, 1);
*   dim3  blocks(1, 1, 1);
*
*   int const example_value = 256;
*
*   threads.x = min(n_fits, example_value);
*   blocks.x = int(ceil(float(n_fits) / float(threads.x)));
*
*   cuda_prepare_next_iteration<<< blocks, threads >>>(
*       lambdas,
*       chi_squares,
*       prev_chi_squares,
*       parameters,
*       prev_parameters,
*       n_fits,
*       n_parameters);
*
*/

__global__ void cuda_prepare_next_iteration(
    float * lambdas,
    float * chi_squares,
    float * prev_chi_squares,
    float * parameters,
    float const * prev_parameters,
    int const n_fits,
    int const n_parameters)
{
    int const fit_index = blockIdx.x * blockDim.x + threadIdx.x;
        
    if (fit_index >= n_fits)
    {
        return;
    }

    if (chi_squares[fit_index] < prev_chi_squares[fit_index])
    {
        lambdas[fit_index] *= 0.1f;
        prev_chi_squares[fit_index] = chi_squares[fit_index];
    }
    else
    {
        lambdas[fit_index] *= 10.f;
        chi_squares[fit_index] = prev_chi_squares[fit_index];
        for (int iparameter = 0; iparameter < n_parameters; iparameter++)
        {
            parameters[fit_index * n_parameters + iparameter] = prev_parameters[fit_index * n_parameters + iparameter];
        }
    }
}
